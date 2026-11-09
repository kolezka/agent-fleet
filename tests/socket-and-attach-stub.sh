#!/usr/bin/env bash
# Local stub test: every CLI path uses the same tmux server, also when FLEET_TMUX_SOCKET comes
# from the environment and the host does not have it; fleet attach refuses names its quoting cannot carry.
# Uses a fake tmux and a fake ssh that drops the environment. No real tmux server, ssh or claude.
# Usage: tests/socket-and-attach-stub.sh. Needs bash 4+.
set -u
P=$(cd "$(dirname "$0")/.." && pwd); fails=0
D=$(mktemp -d "${TMPDIR:-/tmp}/fleetsmoke-sock-XXXXXX") || exit 1
trap 'rm -rf "$D"' EXIT
ok() { echo "PASS $*"; }; no() { echo "FAIL $*"; fails=$((fails+1)); }
mkdir -p "$D/bin" "$D/host"
cp "$P/scripts/watchdog.sh" "$D/host/watchdog.sh"
# The fake tmux prints and logs its arguments, so every call can be checked.
printf '#!/usr/bin/env bash\n{ printf "TMUX"; printf " <%%s>" "$@"; printf "\\n"; } | tee -a %q\n' "$D/tmux.log" > "$D/bin/tmux"
# The fake ssh runs the command without the caller's FLEET_TMUX_SOCKET, like a real remote host.
printf '#!/usr/bin/env bash\n[ "$1" = -t ] && shift\nunset FLEET_TMUX_SOCKET\nexec bash -c "$*"\n' > "$D/bin/ssh-stub"
chmod +x "$D/bin/tmux" "$D/bin/ssh-stub"
cat > "$D/host/fleet.conf" <<EOF
FLEET=sock
FLEET_DIR=$D/host
REMOTE_SSH=$D/bin/ssh-stub
AGENTS=('a|Test|a.txt')
EOF
export PATH="$D/bin:$PATH" FLEET_CONF="$D/host/fleet.conf"
unset FLEET_TMUX_SOCKET
for sock in custom ''; do
  : > "$D/tmux.log"
  FLEET_TMUX_SOCKET="$sock" "$P/scripts/fleet" screen a >/dev/null 2>&1
  FLEET_TMUX_SOCKET="$sock" "$P/scripts/fleet" status >/dev/null 2>&1
  n=$(rg -c '^TMUX' "$D/tmux.log"); n=${n:-0}
  if [ -n "$sock" ]; then bad=$(rg -vc "^TMUX <-L> <$sock> " "$D/tmux.log"); else bad=$(rg -c '<-L>' "$D/tmux.log"); fi
  if [ "$n" -ge 2 ] && [ "${bad:-0}" = 0 ]; then ok "socket <$sock>: all $n tmux calls (screen and helper paths) use the same server"
  else no "socket <$sock>: $n calls, ${bad:-0} on another server: $(tr '\n' ' ' < "$D/tmux.log")"; fi
done
a=$("$P/scripts/fleet" attach a 2>&1); rc=$?
[ "$rc" = 0 ] && [[ "$a" == *"<-L> <fleet-sock>"*"<attach>"* ]] && ok "attach a plain name" || no "attach plain rc=$rc out=[$a]"
"$P/scripts/fleet" attach "agent'one" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "attach refuses a name with a quote" || no "attach quote name rc=$rc want 1"
a=$("$P/scripts/fleet" attach --read-only a 2>&1); rc=$?
[ "$rc" = 0 ] && [[ "$a" == *"<attach> <-f> <read-only,ignore-size> <-t> <a>"* ]] && ok "attach --read-only passes read-only,ignore-size to tmux" || no "attach --read-only rc=$rc out=[$a]"
[[ "$("$P/scripts/fleet" attach a 2>&1)" != *"read-only"* ]] && ok "plain attach stays writable" || no "plain attach got read-only"
echo "failures: $fails"; exit $(( fails > 0 ))
