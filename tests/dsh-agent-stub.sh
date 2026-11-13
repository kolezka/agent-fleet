#!/usr/bin/env bash
# Stub test for AGENT_KIND=dsh: dsh-agent.mjs in a tmux pane, driven by the watchdog helpers.
# A stub dsh prints DSH's --json run events, so no model and no real DSH run.
# Usage: tests/dsh-agent-stub.sh [PLUGIN_DIR]. Needs bash 4+, node 20+, tmux and rg.
set -u
P=$(cd "${1:-$(dirname "$0")/..}" && pwd); fails=0
D=$(mktemp -d "${TMPDIR:-/tmp}/fleetsmoke-dsh-XXXXXX") || exit 1
S=fleetsmoke-dsh-$$
export FLEET_TMUX_SOCKET=fleetsmoke-dsh-$$
pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; fails=$((fails+1)); }
cleanup() { command tmux -L "$FLEET_TMUX_SOCKET" kill-server 2>/dev/null; case "$D" in */fleetsmoke-dsh-*) rm -rf -- "$D" ;; esac; }
trap cleanup EXIT
cp "$P/scripts/watchdog.sh" "$P/scripts/dsh-agent.mjs" "$D/"
# The stub logs its arguments and stdin, then acts on keywords in the message.
cat > "$D/dsh-stub" <<'EOF'
#!/usr/bin/env bash
msg=$(cat); n=$(( $(cat "$STUB_DIR/calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/calls"
printf '%s\n' "$*" > "$STUB_DIR/args-$n"; printf '%s' "$msg" > "$STUB_DIR/msg-$n"
sid=session-stub-1
echo '{"type":"session","sessionId":"'$sid'","cwd":"/x"}'
echo '{"type":"status","phase":"turn_start","turn":1}'
echo '{"type":"status","phase":"step_start","turn":1,"step":1}'
case "$msg" in
  *SLOWTOOL*) echo '{"type":"tool_call","callId":"c1","tool":"bash","input":{"description":"Sleep a while","command":"sleep 30"}}'
    sleep 30 & wait ;;
  *HANG*) exec sleep 600 ;;
  *BADOPT*) echo '{"type":"error","message":"unknown option BADOPT"}'; exit 1 ;;
esac
echo '{"type":"status","phase":"step_end","turn":1,"step":1,"usage":{"totalTokens":420000}}'
echo '{"type":"text","text":"STUBREPLY '$n'"}'
echo '{"type":"status","phase":"turn_end","turn":1,"reason":{"kind":"completed"}}'
echo '{"type":"final","sessionId":"'$sid'","reason":{"kind":"completed"},"text":"STUBREPLY '$n'"}'
EOF
chmod +x "$D/dsh-stub"
cat > "$D/fleet.conf" <<EOF
FLEET=fleetsmoke
FLEET_DIR=$D
AGENT_CWD=$D
AGENT_KIND=dsh
DSH_BIN=$D/dsh-stub
DSH_ARGS="--permission-mode read-only"
AGENTS=("$S|Dsh stub|p.txt")
EOF
printf 'first prompt line\nsecond prompt line\n' > "$D/p.txt"
export STUB_DIR=$D
cd "$D" || exit 9
# shellcheck source=/dev/null
. ./watchdog.sh || { echo "FAIL source"; exit 1; }
pane() { tmux capture-pane -p -S - -t "$S"; }
waitfor() { local _; for _ in $(seq 1 "${2:-20}"); do pane | rg -q -- "$1" && return 0; sleep 0.5; done; return 1; }

# 1. start_agent waits for the ready line, then pastes the prompt as one message.
start_agent "$S" && pass "start_agent succeeded" || { fail "start_agent: $LAUNCH_ERR"; pane | tail -20; }
waitfor 'STUBREPLY 1' && pass "prompt answered" || fail "no reply to the prompt"
[ "$(cat calls 2>/dev/null)" = 1 ] && pass "one dsh run for the multi-line prompt" || fail "dsh runs: $(cat calls 2>/dev/null)"
rg -q 'second prompt line' msg-1 && rg -q 'first prompt line' msg-1 && pass "whole prompt reached dsh" || fail "prompt lost lines"
rg -q -- '--profile headless --permission-mode read-only --json -$' args-1 && pass "first run has DSH_ARGS and no session id" || fail "args-1: $(cat args-1)"
[ -n "$(claude_pid "$S")" ] && pass "claude_pid finds dsh-agent.mjs" || fail "claude_pid empty"
[ "$(ctx_pct "$(screen "$S")")" = 42 ] && pass "ctx_pct reads 42%" || fail "ctx_pct=$(ctx_pct "$(screen "$S")")"
[ -z "$(working_line "$(screen "$S")")" ] && pass "idle: no working line" || fail "working line while idle"
[ -z "$(input_text "$S")" ] && pass "idle: input line empty" || fail "input_text=$(input_text "$S")"

# 2. fleet send's paste_file: delivered, second run resumes the same DSH session.
echo 'second message' > m.txt
out=$(paste_file "$S" m.txt 2>&1); rc=$?
[ "$rc" = 0 ] && pass "paste_file delivered" || fail "paste_file rc=$rc: $out"
waitfor 'STUBREPLY 2' && pass "second message answered" || fail "no second reply"
rg -q -- '--session-id session-stub-1' args-2 && pass "second run resumes the session" || fail "args-2: $(cat args-2)"
# Typed text in the input line blocks a send.
tmux send-keys -t "$S" -l 'human typing'; sleep 1
user_typing "$S" && pass "user_typing sees typed text" || fail "typed text not seen"
paste_file "$S" m.txt >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && pass "send refused while someone types (rc 4)" || fail "rc=$rc want 4"
keys "$S" $'\025'; sleep 1
[ -z "$(input_text "$S")" ] && pass "C-u clears the input line" || fail "input not cleared"

# 3. While a tool runs: working line, tool_running, signature ignores the timer.
echo 'please SLOWTOOL' > m.txt; paste_file "$S" m.txt >/dev/null 2>&1
sleep 3; scr=$(screen "$S"); wl=$(working_line "$scr")
[ -n "$wl" ] && pass "working line: $wl" || { fail "no working line"; printf '%s\n' "$scr" | tail -5; }
tool_running "$(claude_pid "$S")" && pass "tool_running sees the tool under dsh" || fail "tool not seen"
s1=$(signature "$(screen "$S")"); sleep 2; s2=$(signature "$(screen "$S")")
[ "$s1" = "$s2" ] && pass "signature ignores the timer" || fail "signature changes with the timer"

# 4. Escape interrupts the run; the agent is idle again and keeps its session.
keys "$S" $'\e'
waitfor 'Interrupted by user' && pass "Escape interrupts" || fail "no interrupt"
sleep 1; [ -z "$(working_line "$(screen "$S")")" ] && pass "idle after interrupt" || fail "still working"
pgrep -f "sleep 30" >/dev/null && fail "tool process survived the interrupt" || pass "tool process stopped"

# 5. A model step with no output shows "thinking", which gives the watchdog the long limit.
echo 'HANG now' > m.txt; paste_file "$S" m.txt >/dev/null 2>&1; sleep 2
[[ "$(working_line "$(screen "$S")")" == *thinking* ]] && pass "open step shows thinking" || fail "no thinking marker"
keys "$S" $'\e'; sleep 4

# A failed run shows DSH's error event, not just "no output".
echo 'BADOPT' > m.txt; paste_file "$S" m.txt >/dev/null 2>&1
waitfor 'dsh failed \(exit 1\): unknown option BADOPT' && pass "dsh error message shown" || fail "dsh error not shown"

# 6. A permission-dialog look-alike in agent output is not a dialog under AGENT_KIND=dsh.
dialog_kind 'Do you want to proceed?' >/dev/null && fail "dialog_kind fired for dsh" || pass "no dialogs under dsh"

# 7. Replacement kills the wrapper and starts a new one in the same session.
pid=$(claude_pid "$S"); replace "$S" "$pid" >/dev/null 2>&1
waitfor 'dsh-agent ready: Dsh stub \(replacement 1\)' 40 && pass "replacement started" || fail "no replacement"
kill -0 "$pid" 2>/dev/null && fail "old wrapper still alive" || pass "old wrapper gone"

echo "failures: $fails"; exit $(( fails > 0 ))
