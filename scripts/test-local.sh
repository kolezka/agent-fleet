#!/usr/bin/env bash
# Local checks of the fleet CLI with stubs: no agent host, no claude.
# Usage: scripts/test-local.sh [PLUGIN_DIR]   (default: this repo)
# A stub ssh runs the remote side on this machine and can fail or edit a host
# file on a chosen call. tmux runs on a private server under a scratch dir.
set -uo pipefail
P=$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fleetsmoke-local-XXXXXX") || exit 1
unset TMUX
export TMUX_TMPDIR=$T/tmux LC_ALL=${LC_ALL:-en_US.UTF-8}
mkdir -p "$TMUX_TMPDIR" "$T/bin" "$T/tmuxfail"
REAL_TMUX=$(command -v tmux)
SOCK=$TMUX_TMPDIR/tmux-$(id -u)/default
cleanup() {
  [ -S "$SOCK" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null
  case "$T" in */fleetsmoke-local-*) rm -rf -- "$T" ;; esac; }
trap cleanup EXIT
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
show() { printf '%s\n' "$OUT" | sed 's/^/    | /'; }

# Stub ssh: counts calls, appends to STUB_EDIT_FILE before call STUB_EDIT_CALL,
# fails call STUB_FAIL_CALL, otherwise runs the command here.
cat > "$T/bin/stub-ssh" <<'EOF'
#!/usr/bin/env bash
c=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$STUB_COUNT"
[ "$c" = "${STUB_EDIT_CALL:-0}" ] && echo "concurrent host edit" >> "$STUB_EDIT_FILE"
[ "$c" = "${STUB_FAIL_CALL:-0}" ] && { cat >/dev/null; echo "stub: ssh failed" >&2; exit 255; }
exec bash -c "$*"
EOF
# tmux that fails load-buffer, for the paste failure check.
printf '#!/usr/bin/env bash\n[ "$1" = load-buffer ] && exit 1\nexec %q "$@"\n' "$REAL_TMUX" > "$T/tmuxfail/tmux"
chmod +x "$T/bin/stub-ssh" "$T/tmuxfail/tmux"

# new_fleet <name> <stub 0|1> [session...]: scratch fleet with a local "host" dir.
new_fleet() { local n=$1 stub=$2 rows=() s; shift 2
  for s in "$@"; do rows+=("$s|$s|p.txt"); done
  D=$T/$n; mkdir -p "$D"; "$P/scripts/fleet" init "$D/loc" >/dev/null
  { printf 'FLEET=%q\nREMOTE_SSH=%q\nREMOTE_USER=\nFLEET_DIR=%q\nAGENT_CWD=%q\n' "$n" "$([ "$stub" = 1 ] && echo "$T/bin/stub-ssh")" "$D/host" "$D"
    printf 'AGENTS=(%s)\n' "$( [ ${#rows[@]} -gt 0 ] && printf '%q ' "${rows[@]}")"; } > "$D/loc/fleet.conf"
  echo prompt > "$D/loc/p.txt"
  export STUB_COUNT=$D/count; unset STUB_FAIL_CALL STUB_EDIT_CALL STUB_EDIT_FILE; }
fleet() { OUT=$(cd "$D/loc" && FLEET_CONF="$D/loc/fleet.conf" "$P/scripts/fleet" "$@" 2>&1); RC=$?; }
reset_stub() { rm -f "$STUB_COUNT"; }
session() { "$REAL_TMUX" new-session -d -s "$1" -x 200 -y 50 "$2"; }
pane_has() { "$REAL_TMUX" capture-pane -p -S - -t "=$1:" | rg -qF -- "$2"; }

# 1. A failed host hash query must abort the sync, not read as "no host files".
new_fleet f1 1; fleet sync
echo "f1 host edit" >> "$D/host/autonomy.txt"; reset_stub; export STUB_FAIL_CALL=1
fleet sync; unset STUB_FAIL_CALL
if [ "$RC" != 0 ] && rg -qF "f1 host edit" "$D/host/autonomy.txt"; then pass "1 sync aborts when the hash query fails (exit $RC)"; else fail "1 sync aborts when the hash query fails (exit $RC)"; show; fi
chmod 000 "$D/host"; fleet sync; chmod 755 "$D/host"
if [ "$RC" != 0 ] && rg -q "cannot read FLEET_DIR" <<<"$OUT"; then pass "1 sync aborts on an unreadable FLEET_DIR (exit $RC)"; else fail "1 sync aborts on an unreadable FLEET_DIR (exit $RC)"; show; fi

# 2. A host edit made during the sync must not be overwritten or become the baseline.
new_fleet f2 1; fleet sync
reset_stub; export STUB_EDIT_CALL=2 STUB_EDIT_FILE=$D/host/autonomy.txt
fleet sync; first=$RC; unset STUB_EDIT_CALL; fleet sync
if rg -qF "concurrent host edit" "$D/host/autonomy.txt"; then pass "2 concurrent host edit survives (exits $first, $RC)"; else fail "2 concurrent host edit survives (exits $first, $RC)"; show; fi

# 3. File names outside [A-Za-z0-9._-] are refused before anything is copied.
new_fleet f3 0; echo note > "$D/loc/my notes.txt"; fleet sync
if [ "$RC" != 0 ] && [ ! -e "$D/host/fleet.conf" ]; then pass "3 sync refuses a file name with a space (exit $RC)"; else fail "3 sync refuses a file name with a space (exit $RC)"; show; fi

# 4. pull makes the host copy the baseline, so decide right after it works.
session f4a cat
new_fleet f4 0 f4a; fleet sync
echo "f4 host edit" >> "$D/host/autonomy.txt"; fleet pull autonomy.txt
fleet decide "f4 decision"
if [ "$RC" = 0 ] && rg -qF "f4 decision" "$D/host/autonomy.txt"; then pass "4 decide after pull syncs (exit $RC)"; else fail "4 decide after pull syncs (exit $RC)"; show; fi
# A failed decide sync restores the local autonomy.txt.
new_fleet f4b 1; fleet sync; cp "$D/loc/autonomy.txt" "$D/before.txt"
reset_stub; export STUB_FAIL_CALL=3; fleet decide "f4b decision"; unset STUB_FAIL_CALL
if [ "$RC" != 0 ] && cmp -s "$D/before.txt" "$D/loc/autonomy.txt"; then pass "4 failed decide leaves autonomy.txt unchanged (exit $RC)"; else fail "4 failed decide leaves autonomy.txt unchanged (exit $RC)"; show; fi

# 5. A message line FLEET_MSG_EOF must not end the upload and run the rest as shell.
new_fleet f5 0; fleet sync
printf 'hello\nFLEET_MSG_EOF\ntouch %s/pwned\n' "$T" > "$D/m.txt"
fleet send f5-missing "$D/m.txt"
m=$(ls "$D/host"/msg-*-f5-missing.txt 2>/dev/null | head -1)
if [ ! -e "$T/pwned" ] && [ -n "$m" ] && cmp -s "$D/m.txt" "$m"; then pass "5 message bytes arrive intact, nothing runs"; else fail "5 message bytes arrive intact, nothing runs (pwned: $([ -e "$T/pwned" ] && echo yes || echo no))"; show; fi

# 6. A failed paste, or a probe that was only in old scrollback, is not "delivered".
session f6a cat
new_fleet f6 0 f6a; fleet sync
printf 'f6 message one\n' > "$D/m.txt"; fleet send f6a "$D/m.txt"
OUT=$(cd "$D/loc" && PATH="$T/tmuxfail:$PATH" FLEET_CONF="$D/loc/fleet.conf" "$P/scripts/fleet" send f6a "$D/m.txt" 2>&1); RC=$?
if [ "$RC" != 0 ]; then pass "6 failed load-buffer is not delivered (exit $RC)"; else fail "6 failed load-buffer is not delivered (exit $RC)"; show; fi
session f6b "printf 'f6 old line\n'; stty -echo; cat >/dev/null"
printf 'f6 old line\n' > "$D/m2.txt"; fleet send f6b "$D/m2.txt"
if [ "$RC" = 5 ]; then pass "6 probe only in old scrollback is not delivered (exit $RC)"; else fail "6 probe only in old scrollback is not delivered (exit $RC)"; show; fi

# 7. A dialog or other typing that appears during the paste stops the Enter.
session f7a "IFS= read -r a; printf 'Do you want to proceed?\n'; IFS= read -r b; echo GOT-ENTER; cat"
session f7b "printf '\342\235\257 \n'; IFS= read -r a; printf '\342\235\257 someone else typed this\n'; IFS= read -r b; echo GOT-ENTER; cat"
new_fleet f7 0 f7a f7b; fleet sync
printf 'f7 message\n' > "$D/m.txt"
fleet send f7a "$D/m.txt"; sleep 2
if [ "$RC" = 3 ] && ! pane_has f7a GOT-ENTER; then pass "7 dialog during the paste: no Enter (exit $RC)"; else fail "7 dialog during the paste: no Enter (exit $RC)"; show; fi
fleet send f7b "$D/m.txt"; sleep 2
if [ "$RC" = 4 ] && ! pane_has f7b GOT-ENTER; then pass "7 typing during the paste: no Enter (exit $RC)"; else fail "7 typing during the paste: no Enter (exit $RC)"; show; fi
# Positive control for the GOT-ENTER probe: an Enter by hand must show up.
"$REAL_TMUX" send-keys -t "=f7b:" Enter; sleep 1
if pane_has f7b GOT-ENTER; then pass "7 control: the GOT-ENTER probe sees a real Enter"; else fail "7 control: the GOT-ENTER probe sees a real Enter"; fi

# Without echo the pane shows the line once, like Claude Code's input line.
session f7c "stty -echo; cat"
new_fleet f7q 0 f7c; fleet sync
# A quoted dialog line cannot be told apart from a real dialog after the paste, so it is refused.
printf 'f7 quoting: Do you want to proceed?\n' > "$D/m.txt"; fleet send f7c "$D/m.txt"
if [ "$RC" = 8 ]; then pass "7 a message that quotes dialog text is refused (exit $RC)"; else fail "7 a message that quotes dialog text is refused (exit $RC, want 8)"; show; fi
if pane_has f7c 'f7 quoting'; then fail "7 the refused quote message was pasted anyway"; else pass "7 the refused quote message was not pasted"; fi

echo "failures: $FAILS"
[ "$FAILS" = 0 ]
