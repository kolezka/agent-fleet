#!/usr/bin/env bash
# shellcheck disable=SC2034 # DIALOG is read by the sourced watchdog.sh
# Stub tests for launch failures, the trust dialog and paste_file's pre-Enter checks.
# Runs on the agent host in a scratch dir. It never runs the real claude: launch is pointed
# at a stub script by absolute path (CLAUDE_BIN), and the stub leaves a marker when it runs.
# Usage: trust-dialog-stub.sh <scratch dir named fleetsmoke-*, holding watchdog.sh>
set -u
D=${1:?usage: trust-dialog-stub.sh <scratch dir named fleetsmoke-*>}; S=fleetsmoke-trust-$$; P=fleetsmoke-paste-$$; fails=0
# This script deletes $D on exit, so only accept a scratch dir (checked before the trap is set).
[[ "$(basename "$D")" == fleetsmoke-* ]] || { echo "refusing: $D is not a fleetsmoke-* scratch dir" >&2; exit 9; }
pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; fails=$((fails+1)); }
cleanup() { tmux kill-session -t "$S" 2>/dev/null; tmux kill-session -t "$P" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT
cd "$D" || exit 9
TRUST_TEXT=' Is this a project you created or one you trust? ... ❯ No, exit    Yes, I trust this folder'
cat > claude-stub <<EOF
#!/usr/bin/env bash
touch "$D/stub-ran"; printf '%s\n' '$TRUST_TEXT'; exec sleep 600
EOF
chmod +x claude-stub
cat > fleet.conf <<EOF
FLEET=fleetsmoke
FLEET_DIR=$D
AGENT_CWD=$D
CLAUDE_ARGS=
CLAUDE_BIN=$D/claude-stub
AGENTS=("$S|Trust test|p.txt")
EOF
echo hello > p.txt
# shellcheck source=/dev/null
. ./watchdog.sh

# 1. Start into the trust dialog: fails fast, says why, closes its own pane.
tmux new-session -d -s "$S" -x 200 -y 50 "exec cat"
t0=$(date +%s); start_agent "$S"; rc=$?; t=$(( $(date +%s) - t0 ))
[ -f stub-ran ] && pass "the stub (not real claude) was launched" || fail "stub never ran"
[ "$rc" != 0 ] && pass "start_agent fails (rc=$rc)" || fail "start_agent rc=0 on trust dialog"
[ "$t" -lt 20 ] && pass "fails fast (${t}s)" || fail "took ${t}s"
rg -q "$S START FAILED: workspace trust dialog" watchdog.log && pass "log START FAILED with reason" || fail "no START FAILED line"
rg -q "$S STARTED" watchdog.log && fail "STARTED logged on failure" || pass "no STARTED line"
w=$(tmux list-windows -t "$S" | wc -l | tr -d ' ')
[ "$w" = 1 ] && pass "failed start closed its window" || fail "$w windows left, want 1"
pgrep -f "$D/claude-stub" >/dev/null && fail "stub process still running" || pass "no stub process left"

# 2. The watchdog neither types into nor denies a trust dialog. Fake a claude pid so check() takes the dialog path.
tmux send-keys -t "$S" -l "$TRUST_TEXT"; tmux send-keys -t "$S" Enter; sleep 1
k=$(dialog_kind "$(screen "$S")"); [ "$k" = trust ] && pass "dialog_kind=trust" || fail "dialog_kind=$k want trust"
claude_pid() { echo 999999; }
before=$(tmux capture-pane -p -t "$S" | cksum)
DIALOG[$S]=5; check "$S"; sleep 3
after=$(tmux capture-pane -p -t "$S" | cksum)
rg -q "$S state=dialog kind=trust" watchdog.log && pass "check logs kind=trust" || fail "no kind=trust log"
rg -q "$S DENIED" watchdog.log && fail "watchdog denied the trust dialog" || pass "not denied"
[ "$before" = "$after" ] && pass "nothing typed into the pane" || fail "pane changed"

# 3. paste_file pre-Enter checks, on a plain cat pane with stubbed screen readers.
tmux new-session -d -s "$P" -x 200 -y 50 "exec cat"; sleep 1
printf '1. Yes\nDo you want to proceed?\n❯ 1. Yes\n' > quote.txt
paste_file "$P" quote.txt >/dev/null 2>&1; rc=$?
[ "$rc" = 8 ] && pass "message quoting dialog text refused (rc 8)" || fail "quote message rc=$rc want 8"
echo 'hello message' > msg.txt
# The stubs run in command substitutions (subshells), so their call counters live in files.
calls() { local c; c=$(( $(cat "$D/$1" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$D/$1"; echo "$c"; }
# Typed text appended to our paste: the input shows more than our line.
input_text() { [ "$(calls in)" -le 1 ] || echo 'hello message EXTRA HUMAN TEXT'; }
paste_file "$P" msg.txt >/dev/null 2>&1; rc=$?
[ "$rc" = 4 ] && pass "appended typing blocks Enter (rc 4)" || fail "appended typing rc=$rc want 4"
# A late trust dialog: no keys at all, rc 3.
screen() { [ "$(calls scr)" -le 1 ] || printf '%s\n' "$TRUST_TEXT"; }
input_text() { :; }
paste_file "$P" msg.txt >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && pass "late trust dialog blocks Enter (rc 3)" || fail "late trust rc=$rc want 3"
screen() { tmux capture-pane -p -t "$1" 2>/dev/null; }
# A failed pane read is not a baseline of zero.
probe_count() { return 1; }
paste_file "$P" msg.txt >/dev/null 2>&1; rc=$?
[ "$rc" = 7 ] && pass "failed pane read stops the send (rc 7)" || fail "capture failure rc=$rc want 7"

echo "failures: $fails"; exit $(( fails > 0 ))
