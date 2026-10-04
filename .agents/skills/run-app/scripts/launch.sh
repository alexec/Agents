#!/bin/bash
# Build (unless --no-build) and launch a scratch set-up of its own: a control plane, this
# Mac's host on a root of its own, and the window paired with them.
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
HOST_FIRST=0
EXTRA_ENV=()
CONTROL_ENV=()
APP_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build)  BUILD=0 ;;
    --front)     FRONT=1 ;;          # bring the window to the front; steals focus
    --no-window) WINDOW=0 ;;         # the host and control plane only, for socket work
    --first-run) FIRST_RUN=1 ;;      # the window unpaired, on frame K; pair it by hand with PAIR_CODE
    --lan)       LAN=1 ;;            # the control plane at this Mac's LAN address, for a container
    --host-first) HOST_FIRST=1 ;;    # the host starts while the control plane is down, then it comes up (#113)
    --slug)      SLUG="$2"; shift ;;
    --web-port)  WEB_PORT="$2"; shift ;;   # the web remote's port, e.g. one held already (071 R3)
    --seeded)    SEEDED=1 ;;         # the root exists, filled beforehand (scripts/seed-archived.swift), with no control/ yet
    --env)       EXTRA_ENV+=("$2"); shift ;;   # KEY=VALUE for the host, e.g. AGENTS_TEST_…=…
    --control-env) CONTROL_ENV+=("$2"); shift ;;  # KEY=VALUE for the control plane, e.g. AGENTS_SSH=…
    --appearance) APP_ARGS+=(--appearance "$2"); shift ;;  # light|dark|system for the window, no setting changed
    --app-arg)   APP_ARGS+=("$2"); shift ;;   # one more argument for the window, e.g. a defaults key: -key value
    *) echo "usage: launch.sh [--slug NAME] [--seeded] [--no-build] [--front] [--no-window] [--first-run] [--lan] [--host-first] [--web-port N] [--env KEY=VALUE]… [--control-env KEY=VALUE]… [--appearance light|dark] [--app-arg ARG]…" >&2; exit 2 ;;
  esac
  shift
done

[ -n "$SLUG" ] || SLUG="$(printf '%04x' $((RANDOM % 65536)))"
case "$SLUG" in *[!A-Za-z0-9_-]*) echo "a slug is letters, digits, - and _" >&2; exit 2 ;; esac
# Short on purpose: a Unix socket may be named with 104 bytes and no more, and the host's
# socket lives at <root>/daemon.sock. `run-` and not `ag-`, which is the namespace the
# live tests in AgentsKitTests take their own temporary roots from.
ROOT="/tmp/run-$SLUG"

if [ "${SEEDED:-0}" = 1 ]; then
  [ -d "$ROOT" ] && [ ! -e "$ROOT/control" ] && [ ! -e "$ROOT/daemon.sock" ] \
    || { echo "--seeded wants $ROOT made and filled, with nothing running on it" >&2; exit 1; }
elif [ -e "$ROOT" ]; then
  echo "root $ROOT already exists — pick another slug or stop.sh it first" >&2
  exit 1
fi

# Never a copy of the real root's agents (#228): a scratch host resumes any record that
# looks live, with its real runtime session, in its real folder. Seed synthetic ones
# (.agents/reviews/robustness-performance/tools/rp-seed.py, scripts/seed-archived.swift).
REAL_ROOT="$HOME/Library/Application Support/Agents"
if [ -d "$ROOT/agents" ]; then
  # By id: a record whose folder name is one of the real root's agents.
  copied="$( [ -d "$REAL_ROOT/agents" ] && cd "$ROOT/agents" && for id in *; do [ -e "$REAL_ROOT/agents/$id" ] && echo "$id"; done | head -3 || true)"
  # By stamp: a record made in the real root carries its root id.
  if [ -z "$copied" ] && [ -f "$REAL_ROOT/root-id.json" ]; then
    real_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$REAL_ROOT/root-id.json" 2>/dev/null || true)"
    if [ -n "$real_id" ]; then
      copied="$(grep -ls "\"madeInRoot\" *: *\"$real_id\"" "$ROOT"/agents/*/agent.json 2>/dev/null | head -3 || true)"
    fi
  fi
  if [ -n "$copied" ]; then
    echo "refusing: $ROOT/agents holds records copied from the real root ($REAL_ROOT), e.g. $(echo $copied)." >&2
    echo "Seed synthetic agents instead (.agents/reviews/robustness-performance/tools/rp-seed.py); never copy real records." >&2
    exit 1
  fi
fi

if [ "$BUILD" = 1 ]; then
  echo "building…" >&2
  # One after the other: the schemes share SwiftPM state. Through the shared build cache
  # (scripts/build-cache.sh), so a fresh worktree reuses what other builds compiled.
  ( cd "$REPO" && xcodegen generate >/dev/null \
    && scripts/build-cache.sh xcodebuild -scheme AgentsHost -destination 'platform=macOS' -configuration Debug \
         -derivedDataPath build/DD -skipPackagePluginValidation build \
    && scripts/build-cache.sh xcodebuild -scheme AgentsStore -destination 'platform=macOS' -configuration Debug \
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
WEB_PORT="${WEB_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
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
# --host-root: the host's join is in control/status, as on Agents Host's copy (#113).
start_control() {
  "${CLEAN[@]}" ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} AGENTS_CONTROL_URL="$URL" AGENTS_CONTROL_NAME="run-$SLUG" \
    ${SERVERS[@]+"${SERVERS[@]}"} ${CONTROL_ENV[@]+"${CONTROL_ENV[@]}"} \
    nohup "$CONTROL" serve --home "$ROOT/control" --port "$PORT" --no-bonjour \
      --web "$REPO/Web/dist" --web-port "$WEB_PORT" --host-root "$ROOT" \
    >>"$ROOT/control/control.log" 2>&1 &
  echo $! >"$ROOT/control/control.pid"
  for _ in $(seq 1 100); do
    curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 \
    || { echo "the control plane did not answer at $URL — see $ROOT/control/control.log" >&2; exit 1; }
}
start_control

code() { "${CLEAN[@]}" "$CONTROL" code "$@" --home "$ROOT/control" | head -1; }

if [ "$HOST_FIRST" = 1 ]; then
  # #113: the code is made, the control plane stops, and the host starts with the code
  # left in its root, as Agents Host leaves it. It fails to join and keeps trying.
  code --host >"$ROOT/control-join-code"
  kill "$(cat "$ROOT/control/control.pid")"
  for _ in $(seq 1 50); do curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 || break; sleep 0.1; done
fi

# This Mac's host, as Agents Host's launch agent runs it, on the root. Not `env -i`: a
# runtime started without the person's environment cannot sign in. Only what would leak
# this session into it goes: CLAUDE_* and the hosting app's AGENTS_*.
STRIP=()
for name in $(env | grep -oE '^(CLAUDE[A-Z_]*|AGENTS_[A-Z_]*)='); do STRIP+=(-u "${name%=}"); done
if [ "$HOST_FIRST" = 1 ]; then HOST_ARGS=(--control-network); else HOST_ARGS=(--control-code "$(code --host)"); fi
env ${STRIP[@]+"${STRIP[@]}"} AGENTS_ROOT="$ROOT" ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
  nohup "$AGENTSD" "${HOST_ARGS[@]}" >"$ROOT/host.out" 2>&1 &
JOINED="uplink: connected to the control plane"
[ "$HOST_FIRST" = 1 ] && JOINED="uplink: could not join the control plane yet"
for _ in $(seq 1 200); do
  [ -S "$ROOT/daemon.sock" ] && grep -q "$JOINED" "$ROOT/daemon.log" 2>/dev/null && break
  sleep 0.1
done
if [ "$HOST_FIRST" = 1 ]; then
  grep -q "$JOINED" "$ROOT/daemon.log" || { echo "the host never tried to join — see $ROOT/daemon.log" >&2; exit 1; }
  sleep "${HOST_FIRST_WAIT:-5}"
  start_control
  for _ in $(seq 1 300); do grep -q "uplink: connected to the control plane" "$ROOT/daemon.log" && break; sleep 0.1; done
  grep -q "uplink: connected to the control plane" "$ROOT/daemon.log" \
    || { echo "the host did not join once the control plane came up — see $ROOT/daemon.log" >&2; exit 1; }
fi
[ -S "$ROOT/daemon.sock" ] || { echo "no daemon.sock under $ROOT after 20s — see $ROOT/daemon.log and $ROOT/host.out" >&2; exit 1; }
DAEMON_PID="$(tr -d '[:space:]' < "$ROOT/daemon.lock" 2>/dev/null || true)"

APP_PID=""
PAIR_CODE=""
if [ "$WINDOW" = 1 ]; then
  # The window pairs on its own (AGENTS_CONTROL), into a folder of its own in
  # its container (--walk), so it never takes the person's own window's pairing. env -i,
  # because `open` hands this session's environment to the app. --first-run leaves it
  # unpaired, on frame K, with a code to paste into Connect….
  OPEN_FLAGS=(-n)
  [ "$FRONT" = 1 ] || OPEN_FLAGS+=(-g)   # -g: launch behind whatever the person is doing
  if [ "$FIRST_RUN" = 1 ]; then
    PAIR_CODE="$(code --client)"
  else
    OPEN_FLAGS+=(--env AGENTS_CONTROL="$(code --client)")
  fi
  "${CLEAN[@]}" open "${OPEN_FLAGS[@]}" "$APP" --args --walk "run-$SLUG" -ApplePersistenceIgnoreState YES ${APP_ARGS[@]+"${APP_ARGS[@]}"}
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
