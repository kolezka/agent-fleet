#!/usr/bin/env bash
# shellcheck disable=SC2034 # DIALOG is read by the sourced watchdog.sh
# Stub test for findings 8 and 9. Runs on the host in a scratch dir; never launches claude.
# Usage: trust-dialog-stub.sh <dir with watchdog.sh>
set -u
D=$1; S=fleetsmoke-trust-$$; fails=0
pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; fails=$((fails+1)); }
cleanup() { tmux kill-session -t "$S" 2>/dev/null; rm -rf "$D"; }
trap cleanup EXIT
cd "$D" || exit 9
cat > fleet.conf <<EOF
FLEET=fleetsmoke
FLEET_DIR=$D
AGENT_CWD=$D
CLAUDE_ARGS=
AGENTS=("$S|Trust test|p.txt")
EOF
echo hello > p.txt
TRUST_TEXT=' Is this a project you created or one you trust? ... ❯ No, exit    Yes, I trust this folder'
# shellcheck source=/dev/null
. ./watchdog.sh
# A pane that shows the trust dialog; "claude" typed into it is just echoed by cat.
tmux new-session -d -s "$S" -x 200 -y 50 "printf '%s\n' '$TRUST_TEXT'; exec cat"
sleep 1
k=$(dialog_kind "$(screen "$S")"); [ "$k" = trust ] && pass "dialog_kind=trust" || fail "dialog_kind=$k want trust"
t0=$(date +%s); start_agent "$S"; rc=$?; t=$(( $(date +%s) - t0 ))
[ "$rc" != 0 ] && pass "start_agent fails (rc=$rc)" || fail "start_agent rc=0 on trust dialog"
[ "$t" -lt 20 ] && pass "fails fast (${t}s)" || fail "took ${t}s"
rg -q "$S START FAILED: workspace trust dialog" watchdog.log && pass "log START FAILED with reason" || fail "no START FAILED line"
rg -q "$S STARTED" watchdog.log && fail "STARTED logged on failure" || pass "no STARTED line"
# The watchdog must neither type into nor deny it. Fake a claude pid so check() takes the dialog path.
claude_pid() { echo 999999; }
before=$(tmux capture-pane -p -t "$S" | md5sum)
DIALOG[$S]=5; check "$S"; sleep 3
after=$(tmux capture-pane -p -t "$S" | md5sum)
rg -q "$S state=dialog kind=trust" watchdog.log && pass "check logs kind=trust" || fail "no kind=trust log"
rg -q "$S DENIED" watchdog.log && fail "watchdog denied the trust dialog" || pass "not denied"
[ "$before" = "$after" ] && pass "nothing typed into the pane" || fail "pane changed"
echo "failures: $fails"; exit $(( fails > 0 ))
