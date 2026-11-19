#!/usr/bin/env bash
# agent-fleet watchdog. Runs on the agent host, Linux or macOS (bash 4+, tmux, rg).
# Reads fleet.conf from its own directory and checks every agent every 60 s.
# Hung = spinner visible, screen unchanged apart from the timer, no tool process,
# for 3 checks (10 while "thinking"), or claude is gone. Recovery: Esc + nudge,
# then a replacement in the same tmux session and cwd.
# Usage: watchdog.sh [--once] [--dry] [--quiet-start]. Sourcing it loads the
# helpers only (used by `fleet send`, `fleet start`, `fleet status`).
set -u
# macOS ships bash 3.2, which has no associative arrays. Use a newer bash (Homebrew) there.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "watchdog.sh needs bash 4+, this is $BASH_VERSION (on macOS: brew install bash)" >&2; return 2 2>/dev/null || exit 2; }
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$DIR/fleet.conf"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && export CLAUDE_CONFIG_DIR
# The fleet runs on its own tmux server without the user's tmux config, so hooks there
# (extra sidebar panes, focus changes) cannot put the watchdog on the wrong pane.
# FLEET_TMUX_SOCKET= (set but empty) uses the default server instead.
FLEET_TMUX_SOCKET=${FLEET_TMUX_SOCKET-fleet-${FLEET:-default}}
tmux() { if [ -n "$FLEET_TMUX_SOCKET" ]; then command tmux -L "$FLEET_TMUX_SOCKET" -f /dev/null "$@"; else command tmux "$@"; fi; }
LOG=$DIR/watchdog.log
ONCE=0; DRY=0; QUIET=0
# Portable helpers: GNU tools on Linux, BSD tools on macOS (no GNU coreutils needed).
to_epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s; }
pid_cwd() { if [ -d "/proc/$1" ]; then readlink "/proc/$1/cwd"; else lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; fi; }
disk_avail_g() { df -Pk "$1" | awk 'NR==2 { print int($4 / 1048576) }'; }
END_TS=$(to_epoch "${END_AT:-2100-01-01T00:00:00Z}") || { echo "END_AT must look like 2026-11-06T06:00:00Z, got ${END_AT:-}" >&2; return 2 2>/dev/null || exit 2; }
CTX_MAX=${CTX_MAX:-85}
# claude: Claude Code in the pane. dsh: dsh-agent.mjs, a terminal front end for DeepSeek Harness.
AGENT_KIND=${AGENT_KIND:-claude}
case "$AGENT_KIND" in claude|dsh) ;; *) echo "AGENT_KIND must be claude or dsh, got $AGENT_KIND" >&2; return 2 2>/dev/null || exit 2;; esac
for a in "$@"; do case "$a" in --once) ONCE=1;; --dry) DRY=1;; --quiet-start) QUIET=1;; esac; done
declare -A NAME PROMPT SIG STRIKE NUDGED REPL STATE WAIT IDLE_NUDGED WORKRUN LASTNUDGE DIALOG ROT
SESSIONS=()
for row in "${AGENTS[@]}"; do IFS='|' read -r s t p <<<"$row"; SESSIONS+=("$s"); NAME[$s]=$t; PROMPT[$s]=$p
  # The replacement count survives a watchdog restart, so replacement names do not repeat.
  r=$(cat "$DIR/.repl-$s" 2>/dev/null); [[ "$r" =~ ^[0-9]+$ ]] && REPL[$s]=$r; done
TICK=0; LOWDISK_AT=0
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; [ "$ONCE" = 1 ] && printf '%s\n' "$*"; return 0; }

claude_pid() { # newest agent process (claude, or dsh-agent.mjs) in the session's panes
  local pp re='^claude '; [ "$AGENT_KIND" = dsh ] && re='dsh-agent\.mjs( |$)'
  for pp in $(tmux list-panes -s -t "$1" -F '#{pane_pid}' 2>/dev/null); do
    pgrep -P "$pp" -f "$re" ; done | tail -1; }
tool_running() { # a shell or build under the agent that is not an MCP server
  # pgrep -P plus ps -p works on Linux and macOS (macOS ps has no --ppid).
  local kids d p=$1
  # dsh-agent.mjs runs one dsh process per message; the tools are that process's children.
  if [ "$AGENT_KIND" = dsh ]; then p=$(pgrep -P "$1" | paste -sd, -); [ -n "$p" ] || return 1; fi
  kids=$(pgrep -P "$p" | paste -sd, -); [ -n "$kids" ] || return 1
  d=$(ps -o pid=,args= -p "$kids" 2>/dev/null | rg -v "${TOOL_IGNORE:-mcp|codegraph serve|hindsight|npm exec|npx -y|caffeinate|dsh-ptc-runtime}") || return 1
  [ -n "$d" ]; }
screen() { tmux capture-pane -p -t "$1" 2>/dev/null; }
# Type raw bytes into a pane: keys <target> <bytes>, e.g. $'\r' for Enter, $'\e' for Escape.
# send-keys is not used: tmux refuses it from outside while any read-only client
# (fleet attach --read-only) is on the server. A paste without -p is not refused.
# Newer tmux escapes control bytes in a paste unless given -S; older tmux has no -S and does not escape.
keys() { local b=fleetkey-$$-$RANDOM
  [ -n "${PASTE_RAW+x}" ] || { PASTE_RAW=; tmux list-commands paste-buffer 2>/dev/null | rg -q -- '-[a-zA-Z]*S' && PASTE_RAW=-S; }
  printf '%s' "$2" | tmux load-buffer -b "$b" - || return 1
  tmux paste-buffer ${PASTE_RAW:+"$PASTE_RAW"} -d -b "$b" -t "$1" || { tmux delete-buffer -b "$b" 2>/dev/null; return 1; }; }
working_line() { rg -m1 '…\s\((\d+h\s)?(\d+m\s)?\d+s' <<<"$1"; }
signature() { rg -v 'Reset:|Cost:|No credentials|t/s|^\s*$' <<<"$1" \
  | sed -E 's/\((([0-9]+h )?([0-9]+m )?[0-9]+s)( ·|\))/(T\4/' | cksum | cut -d' ' -f1; }

dialog_kind() { # prints trust|protected|other when a dialog is open
  local scr=$1
  # dsh-agent.mjs has no dialogs (headless DSH fails closed), so dialog text there is agent output.
  [ "$AGENT_KIND" = dsh ] && return 1
  # Workspace trust is the owner's call and "deny" would pick "No, exit", so it gets its own kind.
  rg -q 'Is this a project you created or one you trust|Yes, I trust this folder' <<<"$scr" && { echo trust; return 0; }
  rg -q 'Do you want to proceed\?|❯ 1\. Yes' <<<"$scr" || return 1
  rg -q 'git push to a protected target' <<<"$scr" && echo protected || echo other; }
deny_dialog() { local s=$1 k=$2
  [ "$DRY" = 1 ] && { log "$s DRY would deny $k dialog"; return; }
  keys "$s" 2; sleep 2
  dialog_kind "$(screen "$s")" >/dev/null && keys "$s" $'\e'
  log "$s DENIED $k permission dialog (hard limit or unattended)"; }

input_text() { # the text in the input line; empty when it is empty or shows a dim suggestion
  local l; l=$(tmux capture-pane -p -e -t "$1" | rg '❯' | tail -1)
  [[ "$l" == *$'\e[2m'* ]] && return 0
  # Claude Code pads the empty prompt with a no-break space; [[:space:]] misses it.
  printf '%s' "$l" | LC_ALL=C sed 's/\xc2\xa0/ /g' | sed -E 's/\x1b\[[0-9;]*m//g; s/^.*❯[[:space:]]*//; s/[[:space:]]+$//'; }
user_typing() { [ -n "$(input_text "$1")" ]; } # real (not dim suggestion) text in the input line

# Count lines holding $2 in the whole pane history. Fails (rc 1) when the pane cannot be read,
# so a failed capture is never taken as a baseline of zero.
probe_count() { local out; out=$(tmux capture-pane -p -S - -t "$1" 2>/dev/null) || return 1
  rg -cF -- "$2" <<<"$out" || echo 0; }
DIALOG_TEXT='Do you want to proceed\?|❯ 1\. Yes|Is this a project you created or one you trust|Yes, I trust this folder'

# Paste a file into a session and press Enter. Refuses when the file is blank,
# a dialog is open or someone is typing. Exit 0 = pasted and its first
# non-empty line shows up in the pane more often than before the paste.
# Exit 7 = a tmux call failed.
paste_file() { local s=$1 f=$2 probe before _
  # An empty probe would match any pane, so a blank message is refused.
  probe=$(rg -m1 '\S' "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'); probe=${probe:0:40}
  [ -n "$probe" ] || { echo "$s: message file $f is empty or blank, not sent" >&2; return 6; }
  # A message that quotes dialog text would make a real dialog impossible to tell apart
  # from our own paste, and Enter on a dialog can approve it. Such messages are refused.
  rg -q -- "$DIALOG_TEXT" "$f" && { echo "$s: message quotes permission or trust dialog text, not sent (reword it)" >&2; return 8; }
  tmux has-session -t "$s" 2>/dev/null || { echo "no session $s" >&2; return 2; }
  dialog_kind "$(screen "$s")" >/dev/null && { echo "$s: dialog open, not sent" >&2; return 3; }
  user_typing "$s" && { echo "$s: text in the input line, not sent" >&2; return 4; }
  # Old scrollback may already hold the same line, so delivery means the count goes up.
  before=$(probe_count "$s" "$probe") || { echo "$s: tmux could not read the pane, not sent" >&2; return 7; }
  tmux load-buffer -b fleet "$f" || { echo "$s: tmux load-buffer failed, not sent" >&2; return 7; }
  tmux paste-buffer -p -d -b fleet -t "$s" || { echo "$s: tmux paste-buffer failed, not sent" >&2; tmux delete-buffer -b fleet 2>/dev/null; return 7; }
  sleep 1
  # Re-check right before Enter. The message holds no dialog text, so any dialog text now is a real dialog.
  local txt first
  if dialog_kind "$(screen "$s")" >/dev/null; then
    # Keys now would go to the dialog, so none are sent.
    echo "$s: a dialog opened during the paste, Enter not pressed. The pasted text may still be in the input line." >&2; return 3; fi
  txt=$(input_text "$s")
  first=$(rg -m1 '\S' "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  # The input must hold exactly our paste: its whole first line, or Claude Code's
  # [Pasted text #N ...] placeholder and nothing else. Anything more is someone's typing.
  if [ -n "$txt" ] && [ "$txt" != "$first" ] && ! [[ "$txt" =~ ^\[(Pasted\ text|\.\.\.Truncated\ text)\ \#[0-9]+[^]]*\]$ ]]; then
    # C-u clears the input line. Escape would interrupt a working agent and C-c twice exits Claude Code.
    keys "$s" $'\025'; sleep 1
    if user_typing "$s"; then echo "$s: other text appeared in the input line during the paste, Enter not pressed. C-u did not clear the input, check the pane." >&2
    else echo "$s: other text appeared in the input line during the paste, Enter not pressed, input cleared with C-u (including the other text)." >&2; fi
    return 4; fi
  keys "$s" $'\r' || { echo "$s: pasted, but tmux could not press Enter" >&2; return 7; }
  # Claude Code can take several seconds to render a long paste after Enter.
  local now
  for _ in $(seq 1 10); do sleep 1
    now=$(probe_count "$s" "$probe") || { echo "$s: pasted and Enter pressed, but tmux could not read the pane" >&2; return 7; }
    [ "$now" -gt "$before" ] && { echo "$s: delivered"; return 0; }; done
  echo "$s: pasted but first line not found in pane" >&2; return 5; }

idle_nudge() { local s=$1
  user_typing "$s" && { log "$s idle but user is typing, no nudge"; return; }
  dialog_kind "$(screen "$s")" >/dev/null && { log "$s dialog open, no nudge"; return; }
  [ "$DRY" = 1 ] && { log "$s DRY would send idle nudge"; return; }
  tmux load-buffer -b in "$DIR/idle-nudge.txt" && tmux paste-buffer -p -d -b in -t "$s"; sleep 1; keys "$s" $'\r'
  log "$s idle nudge sent"; }

nudge() { local s=$1
  [ "$DRY" = 1 ] && { log "$s DRY would send Esc + nudge"; return; }
  keys "$s" $'\e'; sleep 15
  keys "$s" "Watchdog: you showed no progress for several minutes and were interrupted. Check what you were doing, then continue from there."
  sleep 1; keys "$s" $'\r'
  log "$s nudged (Esc + continue)"; }

# Start claude in session $s (new window if the session exists) and paste prompt file $f.
# All keys go to the new pane by id, never to whatever pane happens to be active.
# On failure LAUNCH_ERR says why and the new pane is closed (its claude, if any, ends unanswered),
# so a retry is not skipped as "already running".
launch() { local s=$1 cwd=$2 n=$3 f=$4 pane ok=0 scr
  LAUNCH_ERR=
  if tmux has-session -t "$s" 2>/dev/null; then pane=$(tmux new-window -P -F '#{pane_id}' -t "$s" -c "$cwd" -n "agent-$(date +%H%M%S)")
  else pane=$(tmux new-session -d -P -F '#{pane_id}' -s "$s" -x 200 -y 50 -c "$cwd"); fi
  [ -n "$pane" ] || { LAUNCH_ERR="tmux could not create a window for $s"; return 4; }
  launch_fail() { LAUNCH_ERR=$1; tmux kill-pane -t "$pane" 2>/dev/null; return "$2"; }
  local cmd ready='bypass permissions on|for shortcuts'
  if [ "$AGENT_KIND" = dsh ]; then ready='dsh-agent ready'
    # DSH_ARGS is split like CLAUDE_ARGS: the shell in the pane parses it.
    cmd="${NODE_BIN:-node} $(printf %q "$DIR/dsh-agent.mjs") --name $(printf %q "$n") --dsh $(printf %q "${DSH_BIN:-dsh}") --context-tokens $(printf %q "${DSH_CONTEXT_TOKENS:-1000000}") -- ${DSH_ARGS:-}"
  else cmd="${CLAUDE_BIN:-claude} -n \"$n\" $(agent_args "$s")"; fi
  keys "$pane" "$cmd"$'\r' || { launch_fail "tmux could not type the $AGENT_KIND command" 4; return; }
  # Paste only once the agent's UI is up. A shell prompt (starship uses ❯ too) would run the text.
  for _ in $(seq 1 45); do sleep 2; scr=$(screen "$pane")
    if [ "$(dialog_kind "$scr")" = trust ]; then
      launch_fail "workspace trust dialog: open claude once in $cwd by hand and trust it" 2; return; fi
    [ -n "$(claude_pid "$s")" ] && rg -q "$ready" <<<"$scr" && { ok=1; break; }; done
  [ "$ok" = 1 ] || { launch_fail "$AGENT_KIND UI not detected after 90 s" 1; return; }
  sleep 2
  # A claude without its prompt is closed too, so a retry starts it cleanly.
  tmux load-buffer -b wd "$f" && tmux paste-buffer -p -d -b wd -t "$pane" || { launch_fail "tmux could not paste $f" 3; return; }
  sleep 2; keys "$pane" $'\r' || { launch_fail "tmux could not press Enter" 3; return; }; }

# Per-agent values: fleet.conf may define agent_overrides, called with the session name, to set
# AGENT_CWD and CLAUDE_ARGS for that agent only. It runs in a subshell, so nothing leaks to the next agent.
agent_cwd() { ( declare -F agent_overrides >/dev/null && agent_overrides "$1"; printf '%s' "${AGENT_CWD:-$HOME}" ); }
agent_args() { ( declare -F agent_overrides >/dev/null && agent_overrides "$1"; printf '%s' "${CLAUDE_ARGS:-}" ); }

# First start of an agent: its prompt file plus autonomy.txt. Prompt copies are private (umask 077).
start_agent() { local s=$1 f=$DIR/start-$1.txt cwd
  cwd=$(agent_cwd "$s")
  ( umask 077; { cat "$DIR/${PROMPT[$s]}"; printf '\n'; [ -f "$DIR/autonomy.txt" ] && cat "$DIR/autonomy.txt"; } > "$f" )
  if ! launch "$s" "$cwd" "${NAME[$s]}" "$f"; then
    log "$s START FAILED: $LAUNCH_ERR (prompt NOT pasted: $f)"; return 1; fi
  log "$s STARTED \"${NAME[$s]}\" in $cwd"; }

replace() { local s=$1 pid=$2 why="hung and was stopped by the watchdog" cwd
  [ "${3:-}" = context ] && why="was retired by the watchdog because its context window was nearly full, after it confirmed its run file and handoff are current"
  cwd=$(agent_cwd "$s")
  if [ -n "$pid" ]; then local c; c=$(pid_cwd "$pid"); [ -d "$c" ] && cwd=$c; fi
  [ "$DRY" = 1 ] && { log "$s DRY would kill pid ${pid:-none} and start a replacement in $cwd"; return; }
  [ -n "$pid" ] && kill "$pid" 2>/dev/null; sleep 5; [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  REPL[$s]=$(( ${REPL[$s]:-0} + 1 )); printf '%s\n' "${REPL[$s]}" > "$DIR/.repl-$s"
  local n="${NAME[$s]} (replacement ${REPL[$s]})" f=$DIR/replace-$s.txt
  ( umask 077; { cat "$DIR/${PROMPT[$s]}"; printf '\n'; [ -f "$DIR/autonomy.txt" ] && cat "$DIR/autonomy.txt"; printf '\n'
    [ -f "$DIR/where-$s.txt" ] && cat "$DIR/where-$s.txt"; printf '\n%s\n' \
"You are a replacement for a session of this agent that $why at $(date -u +%FT%TZ). Do not start over. If you use the phased-delivery skill, follow its references/resume.md: find your run with git worktree list --porcelain and the run file in each worktree's git dir under phased-delivery/run.md, check git status and log against it, and keep working in that same worktree. Read your handoff's session log. Tell me in two lines where you resume and what was uncommitted. Decisions recorded in the run file or the handoff still hold; questions still open there stay open."; } > "$f" )
  if ! launch "$s" "$cwd" "$n" "$f"; then
    log "$s REPLACE FAILED for pid ${pid:-none}: $LAUNCH_ERR (prompt NOT pasted: $f)"; return 1; fi
  log "$s REPLACED pid ${pid:-none} with \"$n\" in $cwd (${3:-hung})"; }

# Context rotation: at CTX_MAX % ask the lead to save state and answer
# CONTEXT-HANDOFF-READY; only then replace it, so its workers are not killed mid-step.
ctx_pct() { local re='/1\.0M\W*\((\d+)%\)'; [ "$AGENT_KIND" = dsh ] && re='dsh context \((\d+)%\)'
  rg -o "$re" -r '$1' <<<"$1" | tail -1; }
ctx_rotate() { local s=$1 pid=$2 scr=$3 p
  [ -n "$pid" ] || return 1
  if [ -n "${ROT[$s]:-}" ]; then
    [ "${STATE[$s]}" = waiting ] && rg -q '^●\W*CONTEXT-HANDOFF-READY\W*$' <<<"$scr" || return 1
    [ "$DRY" = 1 ] && { log "$s DRY would rotate for context"; return 0; }
    replace "$s" "$pid" context; ROT[$s]=; return 0; fi
  p=$(ctx_pct "$scr"); [ -n "$p" ] && [ "$p" -ge "$CTX_MAX" ] || return 1
  if user_typing "$s" || dialog_kind "$scr" >/dev/null; then return 1; fi
  [ "$DRY" = 1 ] && { log "$s DRY would ask for context handoff at ${p}%"; return 1; }
  tmux load-buffer -b cx "$DIR/ctx-handoff.txt" && tmux paste-buffer -p -d -b cx -t "$s"; sleep 1; keys "$s" $'\r'
  ROT[$s]=$(date +%s); log "$s CTXROTATE asked for handoff at ${p}%"; return 1; }

check() { local s=$1 pid scr wl sig limit dk now
  tmux has-session -t "$s" 2>/dev/null || { log "$s tmux session missing, recreating"; replace "$s" ""; return; }
  pid=$(claude_pid "$s"); scr=$(screen "$s"); wl=$(working_line "$scr"); sig=$(signature "$scr")
  dk=$(dialog_kind "$scr")
  if [ -n "$pid" ] && [ -n "$dk" ]; then
    DIALOG[$s]=$(( ${DIALOG[$s]:-0} + 1 )); STRIKE[$s]=0
    log "$s state=dialog kind=$dk count=${DIALOG[$s]} pid=$pid"
    [ "$dk" = trust ] && return # never typed into or denied: the supervisor decides
    if { [ "$dk" = protected ] && [ "${DIALOG[$s]}" -ge 2 ]; } || [ "${DIALOG[$s]}" -ge 3 ]; then deny_dialog "$s" "$dk"; DIALOG[$s]=0; fi
    return
  fi
  DIALOG[$s]=0
  if [ -z "$pid" ]; then STATE[$s]=dead
  elif [ -n "$wl" ]; then
    if tool_running "$pid"; then STATE[$s]=tool
    elif [ "$sig" = "${SIG[$s]:-}" ]; then STATE[$s]=stalled
    else STATE[$s]=working; fi
  else STATE[$s]=waiting; fi
  SIG[$s]=$sig
  case "${STATE[$s]}" in
    dead|stalled) STRIKE[$s]=$(( ${STRIKE[$s]:-0} + 1 ));;
    *) STRIKE[$s]=0; NUDGED[$s]=0;;
  esac
  # Idle nudge: at most one per idle period, re-armed only after 3+ checks of real
  # work, and never more often than every 15 min.
  now=$(date +%s)
  if [ "${STATE[$s]}" = waiting ]; then WAIT[$s]=$(( ${WAIT[$s]:-0} + 1 ))
    [ "${WORKRUN[$s]:-0}" -ge 3 ] && IDLE_NUDGED[$s]=0
    WORKRUN[$s]=0
    if [ "${WAIT[$s]}" -ge 2 ] && [ "${IDLE_NUDGED[$s]:-0}" = 0 ] && [ $(( now - ${LASTNUDGE[$s]:-0} )) -ge 900 ]; then
      idle_nudge "$s"; IDLE_NUDGED[$s]=1; LASTNUDGE[$s]=$now; fi
  elif [ "${STATE[$s]}" = working ] || [ "${STATE[$s]}" = tool ]; then WAIT[$s]=0; WORKRUN[$s]=$(( ${WORKRUN[$s]:-0} + 1 ))
  else WAIT[$s]=0; fi
  # dsh-agent.mjs marks an open model step "thinking" and an open tool call "tool": the screen can hold still there.
  limit=3; [[ "$wl" == *thinking* || "$wl" == *' · tool · '* ]] && limit=10
  log "$s state=${STATE[$s]} strike=${STRIKE[$s]}/$limit pid=${pid:-none} ctx=$(ctx_pct "$scr")%"
  ctx_rotate "$s" "$pid" "$scr" && return
  if [ "${STRIKE[$s]}" -ge "$limit" ]; then
    if [ "${STATE[$s]}" = stalled ] && [ "${NUDGED[$s]:-0}" = 0 ]; then nudge "$s"; NUDGED[$s]=1; STRIKE[$s]=0
    else replace "$s" "$pid"; STRIKE[$s]=0; NUDGED[$s]=0; fi
  fi; }

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0 # sourced: helpers only, no loop
log "watchdog start (once=$ONCE dry=$DRY quiet=$QUIET agents=${#SESSIONS[@]})"
if [ "$QUIET" = 1 ]; then for s in "${SESSIONS[@]}"; do IDLE_NUDGED[$s]=1; LASTNUDGE[$s]=$(date +%s); done; fi
while :; do
  [ "$(date +%s)" -ge "$END_TS" ] && { log "watchdog end time reached, exiting (agents keep running)"; exit 0; }
  TICK=$((TICK+1))
  if [ $((TICK % 10)) = 1 ]; then
    avail=$(disk_avail_g "${DISK_PATH:-/}"); log "disk avail=${avail}G"
    if [ "${avail:-999}" -lt "${DISK_MIN_G:-40}" ] && [ $(( $(date +%s) - LOWDISK_AT )) -ge 21600 ] && [ "$DRY" = 0 ]; then
      LOWDISK_AT=$(date +%s); log "LOWDISK ${avail}G, asking agents to clean up"
      for s in "${SESSIONS[@]}"; do
        dialog_kind "$(screen "$s")" >/dev/null || user_typing "$s" || { keys "$s" "Watchdog: only ${avail}G free on ${DISK_PATH:-/}. When your current step ends, stop emulators and dev servers you do not need and delete build output and worktrees you no longer need, then continue."; sleep 1; keys "$s" $'\r'; }
      done
    fi
  fi
  for s in "${SESSIONS[@]}"; do check "$s"; done
  [ "$ONCE" = 1 ] && break
  sleep 60
done
