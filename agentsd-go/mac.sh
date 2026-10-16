#!/bin/bash
# Stage 5 (#1125): the Go agentsd as this Mac's own host, on a scratch root, with a scratch
# control plane and a scratch window, as run-app's launch.sh sets them up but with the Go
# host in place of the Swift one. Never the live Agents Host: everything is under the root.
#
#   agentsd-go/mac.sh up [slug] [--lan] [--sandbox]   prints ROOT, CONTROL_URL, APP_PID, …
#   agentsd-go/mac.sh down [slug]                     run-app's stop.sh on the root
#
# The window and agents-control come from a scratch build (run-app: launch.sh once without
# --no-build, or the build/DD this worktree already has).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$here/.." && pwd)"
cmd="${1:-up}"; shift || true
SLUG="go1125m"; LAN=0; SANDBOX=0
for a in "$@"; do
  case "$a" in
    --lan) LAN=1 ;;
    --sandbox) SANDBOX=1 ;;
    *) SLUG="$a" ;;
  esac
done
ROOT="/tmp/run-$SLUG"
if [ "$cmd" = down ]; then exec "$REPO/.claude/skills/run-app/scripts/stop.sh" "$ROOT"; fi

HOSTAPP="$REPO/build/DD/Build/Products/Debug/Agents Host.app"
APP="$REPO/build/DD/Build/Products/Debug/Agents.app"
CONTROL="$HOSTAPP/Contents/Helpers/agents-control"
[ -x "$CONTROL" ] && [ -d "$APP" ] || { echo "no scratch build in build/DD: run run-app's launch.sh once" >&2; exit 1; }
[ -e "$ROOT" ] && { echo "$ROOT is there already: mac.sh down $SLUG first" >&2; exit 1; }

# The Go host for this Mac, named agentsd so stop.sh knows it.
mkdir -p "$here/out/darwin"
GOOS=darwin GOARCH=arm64 "$here/go.sh" build -trimpath -o out/darwin/agentsd ./cmd/agentsd
AGENTSD="$here/out/darwin/agentsd"

mkdir -p "$ROOT/control"
CLEAN=(env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8
       PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin")
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
URL="https://127.0.0.1:$PORT"
if [ "$LAN" = 1 ]; then
  ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  URL="https://$ADDRESS:$PORT"
fi
"${CLEAN[@]}" AGENTS_CONTROL_URL="$URL" AGENTS_CONTROL_NAME="run-$SLUG" \
  nohup "$CONTROL" serve --home "$ROOT/control" --port "$PORT" --no-bonjour --no-web --host-root "$ROOT" \
  >>"$ROOT/control/control.log" 2>&1 &
echo $! >"$ROOT/control/control.pid"
for _ in $(seq 1 100); do curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
code() { "${CLEAN[@]}" "$CONTROL" code "$@" --home "$ROOT/control" | head -1; }

# The host first, so it is the home host `mac` (same machine id as the control plane).
# The person's environment, so a runtime can sign in through the Keychain, less this
# session's CLAUDE_* and AGENTS_* (run-app rule 3).
STRIP=()
for name in $(env | grep -oE '^(CLAUDE[A-Z_]*|AGENTS_[A-Z_]*)='); do STRIP+=(-u "${name%=}"); done
env ${STRIP[@]+"${STRIP[@]}"} AGENTS_ROOT="$ROOT" AGENTS_SANDBOX="$SANDBOX" \
  nohup "$AGENTSD" --root "$ROOT" --serve --control-code "$(code --host)" --host-name "This Mac (Go)" >"$ROOT/host.out" 2>&1 &
for _ in $(seq 1 100); do grep -q "uplink: connected" "$ROOT/daemon.log" 2>/dev/null && break; sleep 0.1; done
grep -q "uplink: connected" "$ROOT/daemon.log" || { echo "the Go host did not join — see $ROOT/daemon.log" >&2; exit 1; }

"${CLEAN[@]}" open -n -g --env AGENTS_CONTROL="$(code --client)" "$APP" --args --walk "run-$SLUG" -ApplePersistenceIgnoreState YES
APP_PID=""
for _ in $(seq 1 100); do
  APP_PID="$(pgrep -f "Agents.app/Contents/MacOS/Agents --walk run-$SLUG( |$)" | head -1 || true)"
  [ -n "$APP_PID" ] && break; sleep 0.1
done
cat <<EOF
ROOT=$ROOT
CONTROL_URL=$URL
HOST_PID=$(cat "$ROOT/daemon.lock")
APP_PID=${APP_PID:-none}
LOG=$ROOT/daemon.log
CLIENT_CODE_CMD="$CONTROL" code --client --home $ROOT/control
HOST_CODE_CMD="$CONTROL" code --host --home $ROOT/control
EOF
