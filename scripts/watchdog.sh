#!/usr/bin/env bash
# agent-fleet watchdog. Runs on the agent host (Linux: GNU date, /proc, ps --ppid).
# Reads fleet.conf from its own directory and checks every agent every 60 s.
# Hung = spinner visible, screen unchanged apart from the timer, no tool process,
# for 3 checks (10 while "thinking"), or claude is gone. Recovery: Esc + nudge,
# then a replacement in the same tmux session and cwd.
# Usage: watchdog.sh [--once] [--dry] [--quiet-start]. Sourcing it loads the
# helpers only (used by `fleet send`, `fleet start`, `fleet status`).
set -u
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$DIR/fleet.conf"
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && export CLAUDE_CONFIG_DIR
LOG=$DIR/watchdog.log
ONCE=0; DRY=0; QUIET=0
END_TS=$(date -d "${END_AT:-2100-01-01T00:00:00Z}" +%s)
CTX_MAX=${CTX_MAX:-85}
for a in "$@"; do case "$a" in --once) ONCE=1;; --dry) DRY=1;; --quiet-start) QUIET=1;; esac; done
declare -A NAME PROMPT SIG STRIKE NUDGED REPL STATE WAIT IDLE_NUDGED WORKRUN LASTNUDGE DIALOG ROT
SESSIONS=()
for row in "${AGENTS[@]}"; do IFS='|' read -r s t p <<<"$row"; SESSIONS+=("$s"); NAME[$s]=$t; PROMPT[$s]=$p; done
TICK=0; LOWDISK_AT=0
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; [ "$ONCE" = 1 ] && printf '%s\n' "$*"; return 0; }

claude_pid() { # newest claude process in the session's panes
  local pp; for pp in $(tmux list-panes -s -t "$1" -F '#{pane_pid}' 2>/dev/null); do
    pgrep -P "$pp" -f '^claude ' ; done | tail -1; }
tool_running() { # a shell or build under claude that is not an MCP server
  local d; d=$(ps -o pid=,args= --ppid "$1" 2>/dev/null | rg -v "${TOOL_IGNORE:-mcp|codegraph serve|hindsight|npm exec|npx -y|caffeinate}") || return 1
  [ -n "$d" ]; }
screen() { tmux capture-pane -p -t "$1" 2>/dev/null; }
working_line() { rg -m1 '…\s\((\d+h\s)?(\d+m\s)?\d+s' <<<"$1"; }
signature() { rg -v 'Reset:|Cost:|No credentials|t/s|^\s*$' <<<"$1" \
  | sed -E 's/\((([0-9]+h )?([0-9]+m )?[0-9]+s)( ·|\))/(T\4/' | md5sum | cut -c1-12; }

dialog_kind() { # prints protected|other when a permission dialog is open
  local scr=$1
  rg -q 'Do you want to proceed\?|❯ 1\. Yes' <<<"$scr" || return 1
  rg -q 'git push to a protected target' <<<"$scr" && echo protected || echo other; }
deny_dialog() { local s=$1 k=$2
  [ "$DRY" = 1 ] && { log "$s DRY would deny $k dialog"; return; }
  tmux send-keys -t "$s" 2; sleep 2
  dialog_kind "$(screen "$s")" >/dev/null && tmux send-keys -t "$s" Escape
  log "$s DENIED $k permission dialog (hard limit or unattended)"; }

user_typing() { # real (not dim suggestion) text in the input line
  local l; l=$(tmux capture-pane -p -e -t "$1" | rg '❯' | tail -1)
  [[ "$l" == *$'\e[2m'* ]] && return 1
  # Claude Code pads the empty prompt with a no-break space; [[:space:]] misses it.
  l=$(printf '%s' "$l" | LC_ALL=C sed 's/\xc2\xa0/ /g' | sed -E 's/\x1b\[[0-9;]*m//g; s/^.*❯[[:space:]]*//; s/[[:space:]]+$//')
  [ -n "$l" ]; }

# Paste a file into a session and press Enter. Refuses when the file is blank,
# a dialog is open or someone is typing. Exit 0 = pasted and its first
# non-empty line is visible in the pane.
paste_file() { local s=$1 f=$2 probe _
  # An empty probe would match any pane, so a blank message is refused.
  probe=$(rg -m1 '\S' "$f" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'); probe=${probe:0:40}
  [ -n "$probe" ] || { echo "$s: message file $f is empty or blank, not sent" >&2; return 6; }
  tmux has-session -t "$s" 2>/dev/null || { echo "no session $s" >&2; return 2; }
  dialog_kind "$(screen "$s")" >/dev/null && { echo "$s: dialog open, not sent" >&2; return 3; }
  user_typing "$s" && { echo "$s: text in the input line, not sent" >&2; return 4; }
  tmux load-buffer -b fleet "$f" && tmux paste-buffer -p -d -b fleet -t "$s"; sleep 1; tmux send-keys -t "$s" Enter
  # Claude Code can take several seconds to render a long paste after Enter.
  for _ in $(seq 1 10); do sleep 1
    tmux capture-pane -p -S -400 -t "$s" | rg -qF -- "$probe" && { echo "$s: delivered"; return 0; }; done
  echo "$s: pasted but first line not found in pane" >&2; return 5; }

idle_nudge() { local s=$1
  user_typing "$s" && { log "$s idle but user is typing, no nudge"; return; }
  dialog_kind "$(screen "$s")" >/dev/null && { log "$s dialog open, no nudge"; return; }
  [ "$DRY" = 1 ] && { log "$s DRY would send idle nudge"; return; }
  tmux load-buffer -b in "$DIR/idle-nudge.txt" && tmux paste-buffer -p -d -b in -t "$s"; sleep 1; tmux send-keys -t "$s" Enter
  log "$s idle nudge sent"; }

nudge() { local s=$1
  [ "$DRY" = 1 ] && { log "$s DRY would send Esc + nudge"; return; }
  tmux send-keys -t "$s" Escape; sleep 15
  tmux send-keys -t "$s" -l "Watchdog: you showed no progress for several minutes and were interrupted. Check what you were doing, then continue from there."
  sleep 1; tmux send-keys -t "$s" Enter
  log "$s nudged (Esc + continue)"; }

# Start claude in session $s (new window if the session exists) and paste prompt file $f.
launch() { local s=$1 cwd=$2 n=$3 f=$4
  if tmux has-session -t "$s" 2>/dev/null; then tmux new-window -t "$s" -c "$cwd" -n "agent-$(date +%H%M%S)"
  else tmux new-session -d -s "$s" -x 200 -y 50 -c "$cwd"; fi
  tmux send-keys -t "$s" "claude -n \"$n\" ${CLAUDE_ARGS:-}" Enter
  # Paste only once Claude Code's UI is up. A shell prompt (starship uses ❯ too) would run the text.
  local ok=0; for _ in $(seq 1 45); do sleep 2
    [ -n "$(claude_pid "$s")" ] && screen "$s" | rg -q 'bypass permissions on|for shortcuts' && { ok=1; break; }; done
  [ "$ok" = 1 ] || { log "$s claude UI not detected after 90 s, prompt NOT pasted ($f)"; return 1; }
  sleep 2; tmux load-buffer -b wd "$f" && tmux paste-buffer -p -d -b wd -t "$s"; sleep 2; tmux send-keys -t "$s" Enter; }

# First start of an agent: its prompt file plus autonomy.txt.
start_agent() { local s=$1 f=$DIR/start-$1.txt
  { cat "$DIR/${PROMPT[$s]}"; printf '\n'; [ -f "$DIR/autonomy.txt" ] && cat "$DIR/autonomy.txt"; } > "$f"
  launch "$s" "${AGENT_CWD:-$HOME}" "${NAME[$s]}" "$f"
  log "$s STARTED \"${NAME[$s]}\" in ${AGENT_CWD:-$HOME}"; }

replace() { local s=$1 pid=$2 why="hung and was stopped by the watchdog" cwd
  [ "${3:-}" = context ] && why="was retired by the watchdog because its context window was nearly full, after it confirmed its run file and handoff are current"
  cwd=${AGENT_CWD:-$HOME}
  [ -n "$pid" ] && [ -d "/proc/$pid/cwd" ] && cwd=$(readlink -f "/proc/$pid/cwd")
  [ "$DRY" = 1 ] && { log "$s DRY would kill pid ${pid:-none} and start a replacement in $cwd"; return; }
  [ -n "$pid" ] && kill "$pid" 2>/dev/null; sleep 5; [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  REPL[$s]=$(( ${REPL[$s]:-0} + 1 ))
  local n="${NAME[$s]} (replacement ${REPL[$s]})" f=$DIR/replace-$s.txt
  { cat "$DIR/${PROMPT[$s]}"; printf '\n'; [ -f "$DIR/autonomy.txt" ] && cat "$DIR/autonomy.txt"; printf '\n'
    [ -f "$DIR/where-$s.txt" ] && cat "$DIR/where-$s.txt"; printf '\n%s\n' \
"You are a replacement for a session of this agent that $why at $(date -u +%FT%TZ). Do not start over. If you use the phased-delivery skill, follow its references/resume.md: find your run with git worktree list --porcelain and the run file in each worktree's git dir under phased-delivery/run.md, check git status and log against it, and keep working in that same worktree. Read your handoff's session log. Tell me in two lines where you resume and what was uncommitted. Decisions recorded in the run file or the handoff still hold; questions still open there stay open."; } > "$f"
  launch "$s" "$cwd" "$n" "$f"
  log "$s REPLACED pid ${pid:-none} with \"$n\" in $cwd (${3:-hung})"; }

# Context rotation: at CTX_MAX % ask the lead to save state and answer
# CONTEXT-HANDOFF-READY; only then replace it, so its workers are not killed mid-step.
ctx_pct() { rg -o '/1\.0M\W*\((\d+)%\)' -r '$1' <<<"$1" | tail -1; }
ctx_rotate() { local s=$1 pid=$2 scr=$3 p
  [ -n "$pid" ] || return 1
  if [ -n "${ROT[$s]:-}" ]; then
    [ "${STATE[$s]}" = waiting ] && rg -q '^●\W*CONTEXT-HANDOFF-READY\W*$' <<<"$scr" || return 1
    [ "$DRY" = 1 ] && { log "$s DRY would rotate for context"; return 0; }
    replace "$s" "$pid" context; ROT[$s]=; return 0; fi
  p=$(ctx_pct "$scr"); [ -n "$p" ] && [ "$p" -ge "$CTX_MAX" ] || return 1
  if user_typing "$s" || dialog_kind "$scr" >/dev/null; then return 1; fi
  [ "$DRY" = 1 ] && { log "$s DRY would ask for context handoff at ${p}%"; return 1; }
  tmux load-buffer -b cx "$DIR/ctx-handoff.txt" && tmux paste-buffer -p -d -b cx -t "$s"; sleep 1; tmux send-keys -t "$s" Enter
  ROT[$s]=$(date +%s); log "$s CTXROTATE asked for handoff at ${p}%"; return 1; }

check() { local s=$1 pid scr wl sig limit dk now
  tmux has-session -t "$s" 2>/dev/null || { log "$s tmux session missing, recreating"; replace "$s" ""; return; }
  pid=$(claude_pid "$s"); scr=$(screen "$s"); wl=$(working_line "$scr"); sig=$(signature "$scr")
  dk=$(dialog_kind "$scr")
  if [ -n "$pid" ] && [ -n "$dk" ]; then
    DIALOG[$s]=$(( ${DIALOG[$s]:-0} + 1 )); STRIKE[$s]=0
    log "$s state=dialog kind=$dk count=${DIALOG[$s]} pid=$pid"
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
  limit=3; [[ "$wl" == *thinking* ]] && limit=10
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
    avail=$(df -BG --output=avail "${DISK_PATH:-/}" | tail -1 | tr -dc 0-9); log "disk avail=${avail}G"
    if [ "${avail:-999}" -lt "${DISK_MIN_G:-40}" ] && [ $(( $(date +%s) - LOWDISK_AT )) -ge 21600 ] && [ "$DRY" = 0 ]; then
      LOWDISK_AT=$(date +%s); log "LOWDISK ${avail}G, asking agents to clean up"
      for s in "${SESSIONS[@]}"; do
        dialog_kind "$(screen "$s")" >/dev/null || user_typing "$s" || { tmux send-keys -t "$s" -l "Watchdog: only ${avail}G free on ${DISK_PATH:-/}. When your current step ends, stop emulators and dev servers you do not need and delete build output and worktrees you no longer need, then continue."; tmux send-keys -t "$s" Enter; }
      done
    fi
  fi
  for s in "${SESSIONS[@]}"; do check "$s"; done
  [ "$ONCE" = 1 ] && break
  sleep 60
done
