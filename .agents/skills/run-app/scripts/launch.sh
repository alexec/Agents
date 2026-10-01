#!/bin/bash
# Build (unless --no-build) and launch a copy of Agents on a root of its own.
#
# Prints the root, the app pid and the daemon pid. Everything else in this skill
# takes the root as its first argument.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP="$REPO/build/DD/Build/Products/Debug/Agents.app"
SLUG=""
BUILD=1
FRONT=0
FIRST_RUN=0
EXTRA_ENV=()

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --front)    FRONT=1 ;;          # bring the window to the front; steals focus
    --first-run) FIRST_RUN=1 ;;     # leave the root bare: the window opens on "Where should your agents run?"
    --slug)     SLUG="$2"; shift ;;
    --env)      EXTRA_ENV+=("$2"); shift ;;   # KEY=VALUE for the app, e.g. AGENTS_SSH=…
    *) echo "usage: launch.sh [--slug NAME] [--no-build] [--front] [--first-run] [--env KEY=VALUE]…" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$SLUG" ] || SLUG="$(printf '%04x' $((RANDOM % 65536)))"
# Short on purpose: a Unix socket may be named with 104 bytes and no more, and
# the socket lives at <root>/daemon.sock. `run-` and not `ag-`, which is the
# namespace the live tests in AgentsKitTests take their own temporary roots from.
ROOT="/tmp/run-$SLUG"

if [ -e "$ROOT" ]; then
  echo "root $ROOT already exists — pick another slug or stop.sh it first" >&2
  exit 1
fi

if [ "$BUILD" = 1 ]; then
  echo "building…" >&2
  ( cd "$REPO" && xcodegen generate >/dev/null \
    && xcodebuild -scheme Agents -destination 'platform=macOS' \
         -configuration Debug -derivedDataPath build/DD \
         -skipPackagePluginValidation build >/tmp/run-$SLUG-build.log 2>&1 ) \
    || { echo "build failed — tail /tmp/run-$SLUG-build.log" >&2; tail -30 /tmp/run-$SLUG-build.log >&2; exit 1; }
fi

[ -d "$APP" ] || { echo "no app at $APP — run without --no-build" >&2; exit 1; }

mkdir -p "$ROOT"

# A bare root asks where agents should run (058) and starts no daemon until somebody
# answers, which a walk cannot do without Accessibility. A root that already lists
# projects goes on the old way: the window starts agentsd on it. So seed an empty
# list, unless the first-run screen is what is being walked (--first-run).
[ "$FIRST_RUN" = 1 ] || echo '[]' > "$ROOT/projects.json"

# env -i, because `open` hands this session's environment to the app, and the
# CLAUDE_* variables in it reach every runtime the daemon starts. An agent
# started that way stops authenticating the moment this session ends.
OPEN_FLAGS=(-n)
[ "$FRONT" = 1 ] || OPEN_FLAGS+=(-g)   # -g: launch behind whatever the user is doing
env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin" \
  ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
  open "${OPEN_FLAGS[@]}" "$APP" --args --root "$ROOT"

if [ "$FIRST_RUN" = 1 ]; then
  # No daemon yet: Run One Here starts the control plane and host under launchd,
  # in $ROOT/control. stop.sh boots those jobs out again.
  for _ in $(seq 1 100); do
    APP_PID="$(pgrep -f "Agents.app/Contents/MacOS/Agents .*--root $ROOT" | head -1 || true)"
    [ -n "$APP_PID" ] && break
    sleep 0.1
  done
  printf 'ROOT=%s\nAPP_PID=%s\nDAEMON_PID=none\n' "$ROOT" "${APP_PID:-unknown}"
  exit 0
fi

# The window starts the daemon; the daemon writes the lock and then listens.
for _ in $(seq 1 200); do
  [ -S "$ROOT/daemon.sock" ] && break
  sleep 0.1
done
[ -S "$ROOT/daemon.sock" ] || { echo "no daemon.sock under $ROOT after 20s — see $ROOT/daemon.log" >&2; exit 1; }

APP_PID="$(pgrep -f "Agents.app/Contents/MacOS/Agents .*--root $ROOT" | head -1)"
DAEMON_PID="$(tr -d '[:space:]' < "$ROOT/daemon.lock" 2>/dev/null || true)"

cat <<EOF
ROOT=$ROOT
APP_PID=${APP_PID:-unknown}
DAEMON_PID=${DAEMON_PID:-unknown}
SOCK=$ROOT/daemon.sock
LOG=$ROOT/daemon.log
EOF
