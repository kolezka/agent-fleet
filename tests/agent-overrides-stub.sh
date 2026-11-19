#!/usr/bin/env bash
# Local stub test: agent_overrides in fleet.conf gives one agent its own folder and Claude
# arguments on every launch (start, replacement of a missing session, context replacement of a
# pid whose folder is gone), other agents keep the fleet defaults, nothing leaks into the
# sourcing shell (values or umask), and prompt copies are private even when an older watchdog
# left a 0644 copy. Shell stubs only: no tmux server, no claude.
# Usage: bash tests/agent-overrides-stub.sh [watchdog.sh]   (bash 4 or newer)
W=$(cd "$(dirname "${1:-$(dirname "$0")/../scripts/watchdog.sh}")" && pwd)/$(basename "${1:-watchdog.sh}")
d=$(mktemp -d "${TMPDIR:-/tmp}/fleetsmoke-ovr.XXXX"); trap 'rm -rf "$d"' EXIT
cp "$W" "$d/watchdog.sh"
mkdir -p "$d/own dir"
cat > "$d/fleet.conf" <<EOF
FLEET=x
FLEET_DIR=$d
AGENT_CWD=$d/default
CLAUDE_ARGS="--plain"
AGENTS=("plain|Plain|p.txt" "own|Own|p.txt")
agent_overrides() { case "\$1" in own) AGENT_CWD="$d/own dir"; CLAUDE_ARGS="--dangerously-skip-permissions --model haiku" ;; esac; }
EOF
echo prompt > "$d/p.txt"
# A copy left behind by an older watchdog, readable by others.
for f in start-own.txt replace-own.txt; do echo old > "$d/$f"; chmod 644 "$d/$f"; done
# The inner shell is this script's own bash, so an old bash first on PATH cannot fail quietly.
out=$(cd "$d" && umask 022 && "$BASH" -s <<'EOF'
set -u
. ./watchdog.sh || exit 9
log() { :; }; sleep() { :; }; kill() { :; }
screen() { echo 'bypass permissions on'; }; claude_pid() { echo 123; }
pid_cwd() { echo /no/such/folder; }
# Record where each pane opens and what is typed into it.
tmux() { case "$1" in
  has-session) return 1;;
  new-session) shift; while [ $# -gt 0 ]; do [ "$1" = -c ] && echo "cwd $2" >> calls; shift; done; echo %9;;
  load-buffer) [ "${4:-}" = - ] && cat >> calls && echo >> calls; return 0;;
  *) return 0;; esac; }
start_agent plain; start_agent own; replace own ""; replace own 4242 context
# The override does not leak into the next agent or into this shell.
start_agent plain
echo "shell AGENT_CWD=$AGENT_CWD CLAUDE_ARGS=$CLAUDE_ARGS umask=$(umask)"
for f in start-own.txt replace-own.txt; do echo "mode $f $(ls -l "$f" | cut -c1-10)"; done
cat calls
EOF
) || { echo "inner shell failed (exit $?); run with bash 4 or newer"; exit 9; }
echo "$out"; fails=0
want() { if printf '%s\n' "$out" | grep -qF -- "$1"; then echo "PASS $2"; else echo "FAIL $2 (missing: $1)"; fails=$((fails+1)); fi; }
# calls: per launch a "cwd" line then the typed command; five launches: plain, own, own, own, plain.
mapfile -t L < <(printf '%s\n' "$out" | grep -E '^(cwd |claude )')
[ "${#L[@]}" = 10 ] && echo "PASS five launches recorded" || { echo "FAIL want 10 launch lines, got ${#L[@]}"; fails=$((fails+1)); }
[ "${L[0]}" = "cwd $d/default" ] && [[ "${L[1]}" == *'"Plain" --plain'* ]] && echo "PASS plain agent keeps the fleet defaults" || { echo "FAIL plain: ${L[0]} | ${L[1]}"; fails=$((fails+1)); }
[ "${L[2]}" = "cwd $d/own dir" ] && [[ "${L[3]}" == *'"Own" --dangerously-skip-permissions --model haiku'* ]] && echo "PASS own agent starts with its folder (with a space) and arguments" || { echo "FAIL own start: ${L[2]} | ${L[3]}"; fails=$((fails+1)); }
[ "${L[4]}" = "cwd $d/own dir" ] && [[ "${L[5]}" == *'--dangerously-skip-permissions --model haiku'* ]] && echo "PASS replacing a missing session keeps them" || { echo "FAIL own replace: ${L[4]} | ${L[5]}"; fails=$((fails+1)); }
[ "${L[6]}" = "cwd $d/own dir" ] && [[ "${L[7]}" == *'--dangerously-skip-permissions --model haiku'* ]] && echo "PASS a context replacement whose old folder is gone keeps them" || { echo "FAIL own rotation: ${L[6]} | ${L[7]}"; fails=$((fails+1)); }
[ "${L[8]}" = "cwd $d/default" ] && [[ "${L[9]}" == *'"Plain" --plain'* ]] && echo "PASS nothing leaks to the next agent" || { echo "FAIL plain after own: ${L[8]} | ${L[9]}"; fails=$((fails+1)); }
want "shell AGENT_CWD=$d/default CLAUDE_ARGS=--plain umask=0022" "the sourcing shell keeps the fleet values and its umask"
want "mode start-own.txt -rw-------" "start prompt copy is private even over an older 0644 copy"
want "mode replace-own.txt -rw-------" "replacement prompt copy is private even over an older 0644 copy"
echo "failures: $fails"; exit $(( fails > 0 ))
