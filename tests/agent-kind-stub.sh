#!/usr/bin/env bash
# Local stub test: agent_overrides can set AGENT_KIND and DSH_ARGS for one agent, so a
# Claude fleet can hold one DSH agent. Checks the typed launch command, the process match,
# dialog and context parsing per agent, that nothing leaks to the next agent or the sourcing
# shell, and that an unknown per-agent kind fails the launch before typing.
# Shell stubs only: no tmux server, no claude, no dsh.
# Usage: bash tests/agent-kind-stub.sh [watchdog.sh]   (bash 4 or newer)
W=$(cd "$(dirname "${1:-$(dirname "$0")/../scripts/watchdog.sh}")" && pwd)/$(basename "${1:-watchdog.sh}")
d=$(mktemp -d "${TMPDIR:-/tmp}/fleetsmoke-kind.XXXX"); trap 'rm -rf "$d"' EXIT
cp "$W" "$d/watchdog.sh"
cat > "$d/fleet.conf" <<EOF
FLEET=x
FLEET_DIR=$d
AGENT_CWD=$d
CLAUDE_ARGS="--plain"
DSH_ARGS="--fleet-wide"
AGENTS=("plain|Plain|p.txt" "deep|Deep|p.txt" "odd|Odd|p.txt")
agent_overrides() { case "\$1" in
  deep) AGENT_KIND=dsh; DSH_ARGS="--patch $d/deep.yml --permission-mode workspace-write" ;;
  odd) AGENT_KIND=codex ;;
esac; }
EOF
echo prompt > "$d/p.txt"
out=$(cd "$d" && "$BASH" -s <<'EOF'
set -u
. ./watchdog.sh || exit 9
log() { :; }; sleep() { :; }
# Both ready cues are on screen, so the launch never waits; the typed command is what is checked.
screen() { printf '%s\n' 'bypass permissions on' 'dsh-agent ready: x'; }
pgrep() { echo "pgrep $*" >> pg; echo 77; }
tmux() { case "$1" in
  has-session) return 1;;
  list-panes) echo 500;;
  new-session) echo %9;;
  load-buffer) [ "${4:-}" = - ] && { echo "typed: $(cat)" >> calls; }; return 0;;
  *) return 0;; esac; }
start_agent plain; start_agent deep; start_agent plain
start_agent odd >/dev/null 2>&1; echo "rc-odd $? err=$LAUNCH_ERR"
: > pg; claude_pid plain >/dev/null; claude_pid deep >/dev/null; cat pg
dialog='Do you want to proceed?
❯ 1. Yes'
echo "dialog-plain=$(dialog_kind "$dialog" "$(agent_kind plain)")"
echo "dialog-deep=$(dialog_kind "$dialog" "$(agent_kind deep)" || echo none)"
echo "ctx-deep=$(ctx_pct 'dsh context (42%)' "$(agent_kind deep)")"
echo "ctx-plain=$(ctx_pct 'Ctx 300k/1.0M (30%)' "$(agent_kind plain)")"
echo "shell AGENT_KIND=$AGENT_KIND DSH_ARGS=$DSH_ARGS"
cat calls
EOF
) || { echo "inner shell failed (exit $?); run with bash 4 or newer"; exit 9; }
# Mixed fleet the other way round: the fleet-wide kind is dsh and one agent is Claude Code.
# A Claude dialog must still stop keys at every call site, and an unknown kind must not kill
# the running agent before a replacement can launch.
m=$d/mixed; mkdir -p "$m"; cp "$W" "$m/watchdog.sh"; echo hello > "$m/msg.txt"; echo nudge > "$m/idle-nudge.txt"; echo handoff > "$m/ctx-handoff.txt"
cat > "$m/fleet.conf" <<EOF
FLEET=x
FLEET_DIR=$m
AGENT_KIND=dsh
AGENTS=("cc|Cc|p.txt" "bad|Bad|p.txt")
agent_overrides() { case "\$1" in cc) AGENT_KIND=claude ;; bad) AGENT_KIND=codex ;; esac; }
EOF
echo prompt > "$m/p.txt"
mixed=$(cd "$m" && "$BASH" -s <<'EOF'
set -u
. ./watchdog.sh || exit 9
log() { echo "log: $*"; }; sleep() { :; }; kill() { echo "kill $*"; }
pgrep() { echo 77; }
SCR='Do you want to proceed?
❯ 1. Yes'
screen() { printf '%s\n' "$SCR"; }
tmux() { case "$1" in
  list-panes) echo 500;;
  capture-pane) printf '%s\n' "$SCR";;
  load-buffer|paste-buffer) echo "tmux $1";;
  *) return 0;; esac; }
check cc
paste_file cc msg.txt 2>&1; echo "rc-paste $?"
# The dialog's "❯ 1. Yes" line reads as typing; take that check out so the dialog gate decides.
user_typing() { return 1; }
idle_nudge cc
SCR='Ctx 960k/1.0M (96%)'; STATE[cc]=waiting; CTX_MAX=90
ctx_rotate cc 77 "$SCR"; echo "rc-rot $?"
replace bad 4242; echo "rc-replace $?"
# A dialog that opens during the paste: the first screen is clean, the second shows it.
# screen runs in a command substitution, so the read count lives in a file.
: > reads; screen() { echo x >> reads; if [ "$(wc -l < reads)" -le 1 ]; then echo idle; else printf '%s\n' 'Do you want to proceed?' '❯ 1. Yes'; fi; }
probe_count() { echo 0; }; keys() { echo "keys $(printf '%q' "$2")"; }
paste_file cc msg.txt 2>&1; echo "rc-paste2 $?"
EOF
) || { echo "mixed inner shell failed (exit $?)"; exit 9; }
out=$out$'\n'$mixed
echo "$out"; fails=0
want() { if printf '%s\n' "$out" | grep -qF -- "$1"; then echo "PASS $2"; else echo "FAIL $2 (missing: $1)"; fails=$((fails+1)); fi; }
# Enter is typed too ("typed: " plus a carriage return); only command lines count.
mapfile -t T < <(printf '%s\n' "$out" | grep -E '^typed: (claude|node) ')
[ "${#T[@]}" = 3 ] && echo "PASS three launches typed, none for the unknown kind" || { echo "FAIL want 3 typed commands, got ${#T[@]}"; fails=$((fails+1)); }
[[ "${T[0]:-}" == 'typed: claude -n "Plain" --plain'* ]] && echo "PASS plain agent types claude with CLAUDE_ARGS" || { echo "FAIL plain: ${T[0]:-}"; fails=$((fails+1)); }
[[ "${T[1]:-}" == *"dsh-agent.mjs --name Deep --dsh dsh"*"-- --patch $d/deep.yml --permission-mode workspace-write"* ]] && echo "PASS dsh agent types dsh-agent.mjs with its own DSH_ARGS" || { echo "FAIL deep: ${T[1]:-}"; fails=$((fails+1)); }
[[ -n "${T[1]:-}" && "${T[1]}" != *--fleet-wide* ]] && echo "PASS dsh agent does not get the fleet-wide DSH_ARGS" || { echo "FAIL deep got fleet-wide args or no launch"; fails=$((fails+1)); }
[[ "${T[2]:-}" == 'typed: claude -n "Plain" --plain'* ]] && echo "PASS nothing leaks to the next agent" || { echo "FAIL plain after deep: ${T[2]:-}"; fails=$((fails+1)); }
want "rc-odd 1 err=AGENT_KIND for odd must be claude or dsh, got codex" "an unknown per-agent kind fails before typing"
want "pgrep -P 500 -f ^claude " "plain agent is matched as claude"
want 'pgrep -P 500 -f dsh-agent\.mjs( |$)' "dsh agent is matched as dsh-agent.mjs"
want "dialog-plain=other" "a dialog on a claude agent is a dialog"
want "dialog-deep=none" "dialog text on a dsh agent is output"
want "ctx-deep=42" "dsh context line is read for the dsh agent"
want "ctx-plain=30" "claude context line is read for the claude agent"
want "shell AGENT_KIND=claude DSH_ARGS=--fleet-wide" "the sourcing shell keeps the fleet values"
want "log: cc state=dialog kind=other" "check sees a Claude dialog in a dsh fleet"
want "cc: dialog open, not sent" "paste_file refuses keys on a Claude dialog in a dsh fleet"
want "rc-paste 3" "paste_file returns 3 on that dialog"
want "log: cc dialog open, no nudge" "idle nudge skips a Claude dialog in a dsh fleet"
want "log: cc CTXROTATE asked for handoff at 96%" "context rotation reads the Claude context line in a dsh fleet"
want "(nothing stopped)" "replace with an unknown kind stops nothing"
if printf '%s\n' "$mixed" | grep -q '^kill '; then echo "FAIL replace killed a process for an unknown kind"; fails=$((fails+1)); else echo "PASS no kill for an unknown kind"; fi
if printf '%s\n' "$mixed" | sed -n '/^log: cc state=dialog/,/^rc-paste/p' | grep -q '^tmux \(load\|paste\)-buffer'; then echo "FAIL keys were pasted while the dialog was open"; fails=$((fails+1)); else echo "PASS nothing pasted while the dialog was open"; fi
want "cc: a dialog opened during the paste, Enter not pressed" "paste_file stops before Enter when a Claude dialog opens during the paste"
want "rc-paste2 3" "paste_file returns 3 for a dialog that opened during the paste"
if printf '%s\n' "$mixed" | sed -n '/^rc-replace/,/^rc-paste2/p' | grep -qxF "keys \$'\\r'"; then echo "FAIL Enter pressed on a dialog that opened during the paste"; fails=$((fails+1)); else echo "PASS no Enter on a dialog that opened during the paste"; fi
echo "failures: $fails"; exit $(( fails > 0 ))
