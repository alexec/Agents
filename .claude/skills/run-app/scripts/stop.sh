#!/bin/bash
# Take down one scratch copy: its window, its daemon, its agents, its root.
#
#   stop.sh /tmp/run-xxxx [--keep]    --keep leaves the root on disk to read
#
# Never `pkill -f agentsd`: this session is itself hosted by an Agents daemon,
# and a pattern kill takes that one down with it. The pid in the root's
# daemon.lock is the only daemon this script may touch.
set -euo pipefail

ROOT="${1:-}"
KEEP=0
[ "${2:-}" = "--keep" ] && KEEP=1
# Only a root this skill made. /tmp/ag-* is deliberately not accepted: the live
# tests keep their temporary roots there and they are not ours to delete.
case "$ROOT" in
  /tmp/run-*) ;;
  *) echo "refusing: $ROOT is not a root launch.sh made" >&2; exit 2 ;;
esac

DAEMON_PID="$(tr -d '[:space:]' < "$ROOT/daemon.lock" 2>/dev/null || true)"

for pid in $(pgrep -f "Agents.app/Contents/MacOS/Agents .*--root $ROOT" || true); do
  echo "quitting window $pid"
  kill "$pid" 2>/dev/null || true
done

if [ -n "$DAEMON_PID" ] && ps -p "$DAEMON_PID" >/dev/null 2>&1; then
  # Confirm it is the daemon for this root and not a recycled pid.
  if ps -o command= -p "$DAEMON_PID" | grep -q agentsd; then
    echo "stopping daemon $DAEMON_PID"
    kill "$DAEMON_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do ps -p "$DAEMON_PID" >/dev/null 2>&1 || break; sleep 0.1; done
    ps -p "$DAEMON_PID" >/dev/null 2>&1 && kill -9 "$DAEMON_PID" 2>/dev/null || true
  else
    echo "pid $DAEMON_PID in daemon.lock is not agentsd — leaving it alone" >&2
  fi
fi

# Runtimes and MCP helpers the daemon started carry the root in their argv.
for pid in $(pgrep -f "AGENTS_ROOT.*$ROOT" || true); do kill "$pid" 2>/dev/null || true; done

if [ "$KEEP" = 0 ]; then
  rm -rf "$ROOT"
  echo "removed $ROOT"
else
  echo "kept $ROOT"
fi

# What is left of this root, if anything.
leftover="$(pgrep -f -- "--root $ROOT" || true)"
[ -n "$leftover" ] && { echo "still running: $leftover" >&2; exit 1; }
echo "clean"
