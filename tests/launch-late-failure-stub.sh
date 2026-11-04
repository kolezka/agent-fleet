#!/usr/bin/env bash
# Local stub test: a launch that fails after claude is up (load, paste or Enter) must close its own pane.
# Usage: tests/launch-late-failure-stub.sh [watchdog.sh]. Uses only shell stubs: no tmux server, no claude.
W=${1:-$(dirname "$0")/../scripts/watchdog.sh}; fails=0
for m in load paste enter; do
  out=$(bash -s "$W" "$m" <<'EOF'
set -u; W=$1; mode=$2
log() { :; }; DIR=/tmp; KILLS=$(mktemp); : > $KILLS
. "$W" 2>/dev/null
tmux() { case "$1" in
  has-session) return 0;; new-window) echo %99;; kill-pane) echo "kill $*" >> $KILLS;;
  load-buffer) [ "$mode" = load ] && return 1; return 0;;
  paste-buffer) [ "$mode" = paste ] && return 1; return 0;;
  send-keys) [[ "$*" == *" Enter" && "$*" != *"-n "* && "$mode" = enter ]] && return 1; return 0;;
  *) return 0;; esac; }
sleep() { :; }; screen() { echo 'bypass permissions on'; }; claude_pid() { echo 123; }
launch s /tmp n /dev/null; rc=$?
k=$(rg -c 'kill-pane -t %99' $KILLS); echo "$mode rc=$rc kills=$k"
EOF
)
  echo "$out"; [[ "$out" == *"rc=3 kills=1"* ]] || fails=$((fails+1))
done
echo "failures: $fails"; exit $(( fails > 0 ))
