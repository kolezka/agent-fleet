#!/usr/bin/env bash
# Local stub test: agent_overrides in fleet.conf gives one agent its own folder and Claude
# arguments on every launch (start, replacement of a missing session), other agents keep the
# fleet defaults, and prompt copies are private. Shell stubs only: no tmux server, no claude.
# Usage: tests/agent-overrides-stub.sh [watchdog.sh]
W=$(cd "$(dirname "${1:-$(dirname "$0")/../scripts/watchdog.sh}")" && pwd)/$(basename "${1:-watchdog.sh}")
d=$(mktemp -d "${TMPDIR:-/tmp}/fleetsmoke-ovr.XXXX"); trap 'rm -rf "$d"' EXIT
cp "$W" "$d/watchdog.sh"
cat > "$d/fleet.conf" <<EOF
FLEET=x
FLEET_DIR=$d
AGENT_CWD=$d/default
CLAUDE_ARGS="--plain"
AGENTS=("plain|Plain|p.txt" "own|Own|p.txt")
agent_overrides() { case "\$1" in own) AGENT_CWD=$d/own; CLAUDE_ARGS="--dangerously-skip-permissions --model haiku" ;; esac; }
EOF
echo prompt > "$d/p.txt"
out=$(cd "$d" && umask 022 && bash -s <<'EOF'
set -u
. ./watchdog.sh 2>/dev/null || exit 9
log() { :; }; sleep() { :; }
screen() { echo 'bypass permissions on'; }; claude_pid() { echo 123; }
# Record where each pane opens and what is typed into it.
tmux() { case "$1" in
  has-session) return 1;;
  new-session) shift; while [ $# -gt 0 ]; do [ "$1" = -c ] && echo "cwd $2" >> calls; shift; done; echo %9;;
  load-buffer) [ "${4:-}" = - ] && cat >> calls && echo >> calls; return 0;;
  *) return 0;; esac; }
start_agent plain; start_agent own; replace own ""
# The override does not leak into the next agent or into this shell.
start_agent plain
echo "shell AGENT_CWD=$AGENT_CWD CLAUDE_ARGS=$CLAUDE_ARGS"
for f in start-own.txt replace-own.txt; do echo "mode $f $(ls -l "$f" | cut -c1-10)"; done
cat calls
EOF
)
echo "$out"; fails=0
want() { if printf '%s\n' "$out" | grep -qF -- "$1"; then echo "PASS $2"; else echo "FAIL $2 (missing: $1)"; fails=$((fails+1)); fi; }
# calls: per launch a "cwd" line then the typed command; four launches in order plain, own, own, plain.
mapfile -t L < <(printf '%s\n' "$out" | grep -E '^(cwd |claude )')
[ "${#L[@]}" = 8 ] && echo "PASS four launches recorded" || { echo "FAIL want 8 launch lines, got ${#L[@]}"; fails=$((fails+1)); }
[ "${L[0]}" = "cwd $d/default" ] && [[ "${L[1]}" == *'"Plain" --plain'* ]] && echo "PASS plain agent keeps the fleet defaults" || { echo "FAIL plain: ${L[0]} | ${L[1]}"; fails=$((fails+1)); }
[ "${L[2]}" = "cwd $d/own" ] && [[ "${L[3]}" == *'"Own" --dangerously-skip-permissions --model haiku'* ]] && echo "PASS own agent starts with its folder and arguments" || { echo "FAIL own start: ${L[2]} | ${L[3]}"; fails=$((fails+1)); }
[ "${L[4]}" = "cwd $d/own" ] && [[ "${L[5]}" == *'--dangerously-skip-permissions --model haiku'* ]] && echo "PASS replacing a missing session keeps them" || { echo "FAIL own replace: ${L[4]} | ${L[5]}"; fails=$((fails+1)); }
[ "${L[6]}" = "cwd $d/default" ] && [[ "${L[7]}" == *'"Plain" --plain'* ]] && echo "PASS nothing leaks to the next agent" || { echo "FAIL plain after own: ${L[6]} | ${L[7]}"; fails=$((fails+1)); }
want "shell AGENT_CWD=$d/default CLAUDE_ARGS=--plain" "the sourcing shell keeps the fleet values"
want "mode start-own.txt -rw-------" "start prompt copy is private"
want "mode replace-own.txt -rw-------" "replacement prompt copy is private"
echo "failures: $fails"; exit $(( fails > 0 ))
