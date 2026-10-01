#!/bin/bash
# Build (unless --no-build) and launch a scratch set-up of its own: a control plane, this
# Mac's host on a root of its own, and the window paired with them as an operator.
#
# Prints the root, the window, host and control plane pids, and the control plane's URL.
# Everything else in this skill takes the root as its first argument.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HOSTAPP="$REPO/build/DD/Build/Products/Debug/Agents Host.app"
APP="$REPO/build/DD/Build/Products/Debug/Agents.app"
SLUG=""
BUILD=1
FRONT=0
WINDOW=1
FIRST_RUN=0
LAN=0
EXTRA_ENV=()
CONTROL_ENV=()

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)  BUILD=0 ;;
    --front)     FRONT=1 ;;          # bring the window to the front; steals focus
    --no-window) WINDOW=0 ;;         # the host and control plane only, for socket work
    --first-run) FIRST_RUN=1 ;;      # the window unpaired, on frame K; pair it by hand with PAIR_CODE
    --lan)       LAN=1 ;;            # the control plane at this Mac's LAN address, for a container
    --slug)      SLUG="$2"; shift ;;
    --env)       EXTRA_ENV+=("$2"); shift ;;   # KEY=VALUE for the host, e.g. AGENTS_TEST_…=…
    --control-env) CONTROL_ENV+=("$2"); shift ;;  # KEY=VALUE for the control plane, e.g. AGENTS_SSH=…
    *) echo "usage: launch.sh [--slug NAME] [--no-build] [--front] [--no-window] [--first-run] [--lan] [--env KEY=VALUE]… [--control-env KEY=VALUE]…" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$SLUG" ] || SLUG="$(printf '%04x' $((RANDOM % 65536)))"
case "$SLUG" in *[!A-Za-z0-9_-]*) echo "a slug is letters, digits, - and _" >&2; exit 2 ;; esac
# Short on purpose: a Unix socket may be named with 104 bytes and no more, and the host's
# socket lives at <root>/daemon.sock. `run-` and not `ag-`, which is the namespace the
# live tests in AgentsKitTests take their own temporary roots from.
ROOT="/tmp/run-$SLUG"

if [ -e "$ROOT" ]; then
  echo "root $ROOT already exists — pick another slug or stop.sh it first" >&2
  exit 1
fi

if [ "$BUILD" = 1 ]; then
  echo "building…" >&2
  # One after the other: the schemes share SwiftPM state.
  ( cd "$REPO" && xcodegen generate >/dev/null \
    && xcodebuild -scheme AgentsHost -destination 'platform=macOS' -configuration Debug \
         -derivedDataPath build/DD -skipPackagePluginValidation build \
    && xcodebuild -scheme AgentsStore -destination 'platform=macOS' -configuration Debug \
         -derivedDataPath build/DD -skipPackagePluginValidation build ) >/tmp/run-$SLUG-build.log 2>&1 \
    || { echo "build failed — tail /tmp/run-$SLUG-build.log" >&2; tail -30 /tmp/run-$SLUG-build.log >&2; exit 1; }
fi

CONTROL="$HOSTAPP/Contents/Helpers/agents-control"
AGENTSD="$HOSTAPP/Contents/Helpers/agentsd"
[ -x "$CONTROL" ] && [ -x "$AGENTSD" ] || { echo "no helpers in $HOSTAPP — run without --no-build" >&2; exit 1; }
[ "$WINDOW" = 0 ] || [ -d "$APP" ] || { echo "no window at $APP — run without --no-build" >&2; exit 1; }

mkdir -p "$ROOT/control"
CLEAN=(env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8
       PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin")

# The control plane: a single copy on a free loopback port, its store, key and certificate
# in <root>/control, and no Bonjour, so no window on the network finds it.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
# The web remote (071): the checked-in Web/dist on a free loopback port of the root's own,
# never the live 8792, so a scratch browser's key is bound to a scratch origin.
WEB_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
URL="https://127.0.0.1:$PORT"
if [ "$LAN" = 1 ]; then
  # A container cannot reach this Mac's loopback (test-servers).
  ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  [ -n "$ADDRESS" ] || { echo "no LAN address on en0 or en1 for --lan" >&2; exit 1; }
  URL="https://$ADDRESS:$PORT"
fi
# The Linux hosts a server is given (scripts/build-linux-agentsd.sh), when built.
SERVERS=()
[ -d "$REPO/App/Resources/servers" ] && SERVERS=(AGENTS_CONTROL_SERVERS="$REPO/App/Resources/servers")
"${CLEAN[@]}" ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} AGENTS_CONTROL_URL="$URL" AGENTS_CONTROL_NAME="run-$SLUG" \
  ${SERVERS[@]+"${SERVERS[@]}"} ${CONTROL_ENV[@]+"${CONTROL_ENV[@]}"} \
  nohup "$CONTROL" serve --home "$ROOT/control" --port "$PORT" --no-bonjour \
    --web "$REPO/Web/dist" --web-port "$WEB_PORT" \
  >"$ROOT/control/control.log" 2>&1 &
echo $! >"$ROOT/control/control.pid"
for _ in $(seq 1 100); do
  curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 \
  || { echo "the control plane did not answer at $URL — see $ROOT/control/control.log" >&2; exit 1; }

code() { "${CLEAN[@]}" "$CONTROL" code "$@" --home "$ROOT/control" | head -1; }

# This Mac's host, as Agents Host's launch agent runs it, on the root. Not `env -i`: a
# runtime started without the person's environment cannot sign in. Only what would leak
# this session into it goes: CLAUDE_* and the hosting app's AGENTS_*.
STRIP=()
for name in $(env | grep -oE '^(CLAUDE[A-Z_]*|AGENTS_[A-Z_]*)='); do STRIP+=(-u "${name%=}"); done
env ${STRIP[@]+"${STRIP[@]}"} AGENTS_ROOT="$ROOT" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
  nohup "$AGENTSD" --control-code "$(code --host)" >"$ROOT/host.out" 2>&1 &
for _ in $(seq 1 200); do
  [ -S "$ROOT/daemon.sock" ] && grep -q "uplink: a host of" "$ROOT/daemon.log" 2>/dev/null && break
  sleep 0.1
done
[ -S "$ROOT/daemon.sock" ] || { echo "no daemon.sock under $ROOT after 20s — see $ROOT/daemon.log and $ROOT/host.out" >&2; exit 1; }
DAEMON_PID="$(tr -d '[:space:]' < "$ROOT/daemon.lock" 2>/dev/null || true)"

APP_PID=""
PAIR_CODE=""
if [ "$WINDOW" = 1 ]; then
  # The window pairs as an operator on its own (AGENTS_CONTROL), into a folder of its own in
  # its container (--walk), so it never takes the person's own window's pairing. env -i,
  # because `open` hands this session's environment to the app. --first-run leaves it
  # unpaired, on frame K, with a code to paste into Connect….
  OPEN_FLAGS=(-n)
  [ "$FRONT" = 1 ] || OPEN_FLAGS+=(-g)   # -g: launch behind whatever the person is doing
  if [ "$FIRST_RUN" = 1 ]; then
    PAIR_CODE="$(code --client operator)"
  else
    OPEN_FLAGS+=(--env AGENTS_CONTROL="$(code --client operator)")
  fi
  "${CLEAN[@]}" open "${OPEN_FLAGS[@]}" "$APP" --args --walk "run-$SLUG" -ApplePersistenceIgnoreState YES
  for _ in $(seq 1 100); do
    APP_PID="$(pgrep -f "Agents.app/Contents/MacOS/Agents --walk run-$SLUG( |$)" | head -1 || true)"
    [ -n "$APP_PID" ] && break
    sleep 0.1
  done
fi

cat <<EOF
ROOT=$ROOT
APP_PID=${APP_PID:-none}
DAEMON_PID=${DAEMON_PID:-unknown}
CONTROL_PID=$(cat "$ROOT/control/control.pid")
CONTROL_URL=$URL
WEB_URL=http://localhost:$WEB_PORT/
PAIR_CODE=${PAIR_CODE:-}
SOCK=$ROOT/daemon.sock
LOG=$ROOT/daemon.log
EOF
