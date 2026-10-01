#!/bin/bash
# Take down one scratch set-up: its window, its host, the host's agents, its control
# plane, and its root.
#
#   stop.sh /tmp/run-xxxx [--keep]    --keep leaves the root on disk to read
#
# Never `pkill -f agentsd`: this session is itself hosted by an Agents daemon, and a
# pattern kill takes that one down with it. The pids in the root (daemon.lock,
# control/control.pid) are the only helpers this script may touch.
set -euo pipefail

ROOT="${1:-}"
KEEP=0
[ "${2:-}" = "--keep" ] && KEEP=1
# Only a root this skill made. /tmp/ag-* is deliberately not accepted: the live tests
# keep their temporary roots there and they are not ours to delete.
case "$ROOT" in
  /tmp/run-*) ;;
  *) echo "refusing: $ROOT is not a root launch.sh made" >&2; exit 2 ;;
esac
WALK="${ROOT#/tmp/}"

# Stop a pid from the root, once it is checked to be the program named and not a
# recycled pid.
stop_pid() { # pid program-name what
  local pid="$1" name="$2" what="$3"
  [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1 || return 0
  if ps -o command= -p "$pid" | grep -q "$name"; then
    echo "stopping $what $pid"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do ps -p "$pid" >/dev/null 2>&1 || break; sleep 0.1; done
    ps -p "$pid" >/dev/null 2>&1 && kill -9 "$pid" 2>/dev/null || true
  else
    echo "pid $pid is not $name — leaving it alone" >&2
  fi
}

# A scratch Agents Host on this root (AGENTS_ROOT=$ROOT) leaves launchd jobs of its own,
# labelled by the root's hash, their plists in $ROOT, $ROOT/control or $ROOT/host. They are
# KeepAlive, so they go first: a helper killed before its job is booted out is started
# again at once. Only labels whose plist is in this root are touched.
for plist in "$ROOT"/com.alexecollins.agentshost.*.scratch-*.plist "$ROOT"/control/com.alexecollins.agentshost.*.scratch-*.plist "$ROOT"/host/com.alexecollins.agentshost.*.scratch-*.plist; do
  [ -e "$plist" ] || continue
  label="$(basename "$plist" .plist)"
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    echo "booting out $label"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  fi
done

for pid in $(pgrep -f "Agents.app/Contents/MacOS/Agents --walk $WALK( |$)" || true); do
  echo "quitting window $pid"
  kill "$pid" 2>/dev/null || true
done

stop_pid "$(tr -d '[:space:]' < "$ROOT/daemon.lock" 2>/dev/null || true)" agentsd host
stop_pid "$(tr -d '[:space:]' < "$ROOT/control/control.pid" 2>/dev/null || true)" agents-control "control plane"

# Runtimes and MCP helpers the host started carry the root in their argv or environment.
for pid in $(pgrep -f "AGENTS_ROOT.*$ROOT" || true); do kill "$pid" 2>/dev/null || true; done

# The window's pairing for this walk, in its container.
rm -rf "$HOME/Library/Containers/com.alexecollins.agents.store/Data/Library/Application Support/Agents/walks/$WALK"

if [ "$KEEP" = 0 ]; then
  rm -rf "$ROOT"
  echo "removed $ROOT"
else
  echo "kept $ROOT"
fi

# What is left of this set-up, if anything.
leftover="$(pgrep -f -- "--walk $WALK( |$)|--home $ROOT/control" || true)"
[ -n "$leftover" ] && { echo "still running: $leftover" >&2; exit 1; }
echo "clean"
