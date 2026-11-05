#!/usr/bin/env bash
# Checks the watchdog helpers that differ between Linux and macOS. Local, harmless: sleeps and a temp dir.
# Usage: tests/portable-helpers.sh [watchdog.sh]. On macOS run it with a bash 4+ (Homebrew).
set -u; W=${1:-$(dirname "$0")/../scripts/watchdog.sh}; fails=0
ok() { echo "PASS $*"; }; no() { echo "FAIL $*"; fails=$((fails+1)); }
d=$(mktemp -d /tmp/fleetsmoke-port.XXXX); cp "$W" "$d/watchdog.sh"; printf 'FLEET=x\nAGENTS=()\nEND_AT=2100-01-01T00:00:00Z\n' > "$d/fleet.conf"
cd "$d" && . ./watchdog.sh || { echo "FAIL source rc=$?"; exit 1; }
[ "$END_TS" = 4102444800 ] && ok "END_AT to epoch" || no "END_TS=$END_TS"
sleep 30 & sp=$!; (cd /tmp && sleep 30) & cp=$!
bash -c 'sleep 30 & wait' & parent=$!; sleep 1
tool_running $parent && ok "tool_running sees a child process" || no "tool_running missed a child"
tool_running $sp && no "tool_running on a leaf process" || ok "no children means no tool"
c=$(pid_cwd $cp); [ "$(cd "$c" && pwd -P)" = "$(cd /tmp && pwd -P)" ] && ok "pid_cwd=$c" || no "pid_cwd=$c"
a=$(disk_avail_g /); [[ "$a" =~ ^[0-9]+$ ]] && ok "disk avail ${a}G" || no "disk avail '$a'"
s1=$(signature "abc"); s2=$(signature "abc"); s3=$(signature "abd"); [ "$s1" = "$s2" ] && [ "$s1" != "$s3" ] && ok "signature stable" || no "signature $s1 $s2 $s3"
kill $sp $cp $parent 2>/dev/null; pkill -P $parent 2>/dev/null; rm -rf "$d"
echo "failures: $fails"; exit $(( fails > 0 ))
