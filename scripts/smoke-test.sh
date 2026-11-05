#!/usr/bin/env bash
# Smoke test of the fleet CLI against a real host (Linux or macOS) or this machine ("local"), with a scratch fleet.
# Usage: scripts/smoke-test.sh <REMOTE_SSH|local> [REMOTE_USER] [HOST_BASE_DIR]
# Every name it creates starts with fleetsmoke-<random>. It never starts claude
# (no `fleet start`, no `fleet watchdog start`), and it removes its scratch tmux
# sessions and dirs on exit.
set -uo pipefail
REMOTE_SSH=${1:?usage: scripts/smoke-test.sh <REMOTE_SSH|local> [REMOTE_USER] [HOST_BASE_DIR]}
# "local" tests the one-machine setup: agents, watchdog and supervisor on this machine, no ssh.
[ "$REMOTE_SSH" = local ] && REMOTE_SSH=
REMOTE_USER=${2:-}; BASE=${3:-/tmp}
FLEET_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet
ID=fleetsmoke-$RANDOM$RANDOM
HOST_DIR=${BASE%/}/$ID
A=$ID-a; B=$ID-b; DLG=$ID-dlg; MISSING=$ID-missing
LOCAL=$(mktemp -d "${TMPDIR:-/tmp}/fleetsmoke-XXXXXX") || exit 1
FAILS=0

# Scratch sessions go on the fleet's own tmux server (fleet-<FLEET>), like the CLI's.
rx() { { printf 'tmux() { command tmux -L %q -f /dev/null "$@"; }\n' "fleet-$ID"; cat; } | rx_raw; }
rx_raw() {
  if [ -z "$REMOTE_SSH" ]; then bash -s
  elif [ -n "$REMOTE_USER" ]; then $REMOTE_SSH "su - $REMOTE_USER -c 'bash -s'"
  else $REMOTE_SSH 'bash -s'; fi
}

cleanup() { local rc=$? left
  # Only names with this run's prefix are touched. "=" makes tmux match the exact name.
  printf 'tmux ls -F "#{session_name}" 2>/dev/null | rg "^%s-" | while read -r s; do tmux kill-session -t "=$s"; done\n' "$ID" | rx
  printf 'case %q in */fleetsmoke-*) rm -rf -- %q ;; esac\n' "$HOST_DIR" "$HOST_DIR" | rx
  case "$LOCAL" in */fleetsmoke-*) rm -rf -- "$LOCAL" ;; esac
  left=$(printf 'n=$(tmux ls -F "#{session_name}" 2>/dev/null | rg -c "^%s-"); [ -e %q ] && d=yes || d=no; echo "${n:-0} $d"\n' "$ID" "$HOST_DIR" | rx)
  if [ "$left" = "0 no" ] && [ ! -e "$LOCAL" ]; then echo "PASS cleanup: no $ID sessions, host and local scratch dirs removed"
  else echo "FAIL cleanup: sessions/host dir left: $left, local dir exists: $([ -e "$LOCAL" ] && echo yes || echo no)"; rc=1; fi
  exit "$rc"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
show() { printf '%s\n' "$OUT" | sed 's/^/    | /'; }
fleet() { OUT=$(cd "$LOCAL" && FLEET_CONF="$LOCAL/fleet.conf" "$FLEET_BIN" "$@" 2>&1); RC=$?; }
# check <name> <expected rc> [fixed string the output must contain...]
check() { local name=$1 want=$2 s; shift 2
  [ "$RC" = "$want" ] || { fail "$name (exit $RC, want $want)"; show; return; }
  for s in "$@"; do rg -qF -- "$s" <<<"$OUT" || { fail "$name (output lacks: $s)"; show; return; }; done
  pass "$name (exit $RC)"; }
host_has() { printf 'rg -q -- %q %q\n' "$2" "$1" | rx; } # host_has <file> <regex>

echo "scratch fleet $ID, host dir $HOST_DIR, local dir $LOCAL"
fleet init "$LOCAL"; check "init" 0 "created"
{ printf 'FLEET=%q\nREMOTE_SSH=%q\nREMOTE_USER=%q\nFLEET_DIR=%q\nAGENT_CWD=%q\n' "$ID" "$REMOTE_SSH" "$REMOTE_USER" "$HOST_DIR" "$HOST_DIR"
  printf 'CLAUDE_ARGS=""\nEND_AT=2100-01-01T00:00:00Z\nCTX_MAX=85\nDISK_PATH=/; DISK_MIN_G=1\n'
  printf 'AGENTS=(%q %q)\n' "$A|Smoke A|a.txt" "$B|Smoke B|b.txt"; } > "$LOCAL/fleet.conf"
echo "smoke prompt, never sent to claude" > "$LOCAL/a.txt"; cp "$LOCAL/a.txt" "$LOCAL/b.txt"

fleet sync; check "sync" 0 "synced:"

fleet watchdog dry; check "watchdog dry" 0 "DRY would"
if rg -q 'line [0-9]+:' <<<"$OUT"; then fail "watchdog dry has bash errors"; else pass "watchdog dry has no bash errors"; fi
if printf 'tmux has-session -t %q 2>/dev/null\n' "=$A" | rx; then fail "watchdog dry created a session"; else pass "watchdog dry started nothing"; fi

# Plain scratch sessions running cat stand in for agents. One shows a permission dialog.
printf 'tmux new-session -d -s %q -x 200 -y 50 cat && tmux new-session -d -s %q -x 200 -y 50 cat && tmux new-session -d -s %q -x 200 -y 50 %q\n' \
  "$A" "$B" "$DLG" "printf 'Do you want to proceed?\n  1. Yes\n  2. No\n'; exec cat" | rx \
  && pass "scratch sessions created" || fail "scratch sessions created"

printf 'smoke send %s\nsecond line\n' "$ID" > "$LOCAL/m-send.txt"
fleet send "$A" "$LOCAL/m-send.txt"; check "send delivers" 0 "$A: delivered"
printf '\n   \nsmoke leading blank %s\n' "$ID" > "$LOCAL/m-blank-first.txt"
fleet send "$A" "$LOCAL/m-blank-first.txt"; check "send with blank first line delivers" 0 "$A: delivered"
fleet send "$DLG" "$LOCAL/m-send.txt"; check "send refuses on dialog" 3 "dialog open"
fleet send "$MISSING" "$LOCAL/m-send.txt"; check "send to missing session" 2 "no session"
: > "$LOCAL/m-empty.txt"
fleet send "$A" "$LOCAL/m-empty.txt"; check "send refuses empty file" 6 "empty or blank"
printf ' \n\t\n' > "$LOCAL/m-ws.txt"
fleet send "$A" "$LOCAL/m-ws.txt"; check "send refuses whitespace-only file" 6 "empty or blank"
printf 'smoke inject %s\nFLEET_MSG_EOF\ntouch %s/pwned\n' "$ID" "$HOST_DIR" > "$LOCAL/m-inject.txt"
fleet send "$A" "$LOCAL/m-inject.txt"; check "send with a FLEET_MSG_EOF line delivers" 0 "$A: delivered"
if printf 'test -e %q/pwned\n' "$HOST_DIR" | rx; then fail "message text ran as shell on the host"; else pass "message text did not run as shell on the host"; fi
# The first line is only in old scrollback and the paste does not show: not delivered.
printf 'tmux new-session -d -s %q -x 200 -y 50 %q\n' "$ID-old" "printf 'smoke old line $ID\n'; stty -echo; exec cat >/dev/null" | rx
printf 'smoke old line %s\n' "$ID" > "$LOCAL/m-old.txt"
fleet send "$ID-old" "$LOCAL/m-old.txt"; check "send does not count old scrollback as delivery" 5 "not found"
# A dialog that opens during the paste stops the Enter.
printf 'tmux new-session -d -s %q -x 200 -y 50 %q\n' "$ID-late" "IFS= read -r a; printf 'Do you want to proceed?\n'; IFS= read -r b; echo GOT-ENTER; exec cat" | rx
printf 'smoke late dialog %s\n' "$ID" > "$LOCAL/m-late.txt"
fleet send "$ID-late" "$LOCAL/m-late.txt"; check "send stops when a dialog opens during the paste" 3 "Enter not pressed"
sleep 2
late_enter() { printf 'tmux capture-pane -p -S - -t %q | rg -q GOT-ENTER\n' "=$ID-late:" | rx; }
if late_enter; then fail "no Enter reached the late-dialog pane"; else pass "no Enter reached the late-dialog pane"; fi
printf 'tmux send-keys -t %q Enter\n' "=$ID-late:" | rx; sleep 1
if late_enter; then pass "control: a real Enter shows as GOT-ENTER"; else fail "control: a real Enter shows as GOT-ENTER"; fi

printf 'echo %q >> %q/autonomy.txt\n' "host edit $ID" "$HOST_DIR" | rx
fleet sync; check "sync refuses after a host edit" 1 "sync refused" "autonomy.txt"
fleet pull autonomy.txt; check "pull" 0 "pulled autonomy.txt"
if rg -qF "host edit $ID" "$LOCAL/autonomy.txt"; then pass "pull brought the host edit"; else fail "pull brought the host edit"; fi
fleet sync; check "sync after pull" 0 "synced:"
printf 'echo %q >> %q/autonomy.txt\n' "second host edit $ID" "$HOST_DIR" | rx
fleet sync; check "sync refuses a second host edit" 1 "sync refused"
fleet sync --force; check "sync --force" 0 "synced:"
if host_has "$HOST_DIR/autonomy.txt" "second host edit"; then fail "sync --force replaced the host file"; else pass "sync --force replaced the host file"; fi

printf 'smoke broadcast %s\n' "$ID" > "$LOCAL/m-bc.txt"
fleet broadcast "$LOCAL/m-bc.txt"; check "broadcast to two agents" 0 "$A: delivered (exit 0)" "$B: delivered (exit 0)"

printf 'echo %q >> %q/autonomy.txt\n' "third host edit $ID" "$HOST_DIR" | rx
fleet pull autonomy.txt; check "pull before decide" 0 "pulled autonomy.txt"
fleet decide "smoke decision one $ID"; check "decide 1 right after a pull" 0 "$A: delivered (exit 0)" "$B: delivered (exit 0)"
if rg -q "^1\. Decision from the owner \(.*relayed by the supervisor\): smoke decision one $ID\$" "$LOCAL/autonomy.txt"; then pass "decide 1 appended rule 1"; else fail "decide 1 appended rule 1"; fi
fleet decide "smoke decision two $ID"; check "decide 2" 0 "$A: delivered (exit 0)"
if rg -q "^2\. Decision from the owner .*: smoke decision two $ID\$" "$LOCAL/autonomy.txt"; then pass "decide 2 appended rule 2"; else fail "decide 2 appended rule 2"; fi
if host_has "$HOST_DIR/autonomy.txt" "^2\. Decision from the owner .*smoke decision two"; then pass "decide synced the rule to the host"; else fail "decide synced the rule to the host"; fi
# The broadcast text must not start with a digit (a "1" could pick a dialog's first option).
if printf 'cd %q && f=$(ls -t msg-*-broadcast.txt | head -1) && head -1 "$f" | rg -q "^New rule 2, added to autonomy.txt: Decision from the owner .*smoke decision two"\n' "$HOST_DIR" | rx; then pass "decide broadcast starts with words, not a digit"; else fail "decide broadcast starts with words, not a digit"; fi

left=$(printf 'ls -A %q | rg "^\\.fleet-sync-" | rg -v "^\\.fleet-sync-manifest\$" || true\n' "$HOST_DIR" | rx)
if [ -z "$left" ]; then pass "no sync temp dir left on the host"; else fail "sync temp dirs left on the host: $left"; fi
if printf 'test -s %q/.fleet-sync-manifest\n' "$HOST_DIR" | rx; then pass "control: the sync manifest is there"; else fail "control: the sync manifest is there"; fi
printf 'tmux kill-session -t %q\n' "=$B" | rx
printf 'smoke broadcast partial %s\n' "$ID" > "$LOCAL/m-bc2.txt"
fleet broadcast "$LOCAL/m-bc2.txt"; check "broadcast reports a missing agent" 1 "$A: delivered (exit 0)" "$B: NOT delivered (exit 2)"

fleet handoff; check "handoff prints the skeleton" 0 "## 1. Where things run" "## 3. Monitor" "## 9. Transcript" "\`$A\` \"Smoke A\"" "msg-"
fleet handoff smoke; check "handoff writes a file" 0 "HANDOFF-smoke.md"
fleet handoff smoke; check "handoff refuses to overwrite" 1 "not overwriting"

echo "failures: $FAILS"
[ "$FAILS" = 0 ]
