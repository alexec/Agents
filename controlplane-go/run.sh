#!/bin/bash
# The Go control plane (#1126 spike) on a scratch root, with today's Swift host and window
# paired to it, as run-app's launch.sh sets up the Swift one. Never the live control
# plane or Agents Host: everything is under /tmp/run-<slug>.
#
#   controlplane-go/run.sh up [slug] [--s3] [--kms] [--lan] [--no-window] [--no-web]
#        --s3        the store in MinIO (./minio.sh up first), not a folder
#        --kms       the control plane's key sealed by a local keeper (stage 4)
#        --lan       at this Mac's LAN address, so the agents-devbox container can join
#   controlplane-go/run.sh code [slug] --client|--host|--client --browser
#   controlplane-go/run.sh down [slug]
#
# Needs a scratch build in build/DD (run-app's launch.sh once, or the xcodebuild lines in
# REPORT.md) and the Go binary: GOOS=darwin ./go.sh build -o out/darwin/agents-control ./cmd/agents-control
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$here/.." && pwd)"
cmd="${1:-up}"; shift || true
SLUG="cpgo"; S3=0; KMS=0; LAN=0; WINDOW=1; WEB=1; REST=()
for a in "$@"; do
  case "$a" in
    --s3) S3=1 ;; --kms) KMS=1 ;; --lan) LAN=1 ;; --no-window) WINDOW=0 ;; --no-web) WEB=0 ;;
    --*) REST+=("$a") ;;
    *) SLUG="$a" ;;
  esac
done
ROOT="/tmp/run-$SLUG"
HOSTAPP="$REPO/build/DD/Build/Products/Debug/Agents Host.app"
APP="$REPO/build/DD/Build/Products/Debug/Agents.app"
AGENTSD="$HOSTAPP/Contents/Helpers/agentsd"
CONTROL="$here/out/darwin/agents-control"
CLEAN=(env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TMPDIR="${TMPDIR:-/tmp}" LANG=en_US.UTF-8
       PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin")
STORE_ENV=()
if [ -f "$ROOT/control/store.env" ]; then while read -r l; do STORE_ENV+=("$l"); done <"$ROOT/control/store.env"; fi

case "$cmd" in
down) exec "$REPO/.claude/skills/run-app/scripts/stop.sh" "$ROOT" ${REST[@]+"${REST[@]}"} ;;
code) "${CLEAN[@]}" ${STORE_ENV[@]+"${STORE_ENV[@]}"} "$CONTROL" code ${REST[@]+"${REST[@]}"} --home "$ROOT/control"; exit ;;
up) ;;
*) echo "say up, code or down" >&2; exit 2 ;;
esac

[ -x "$CONTROL" ] || { echo "no $CONTROL: GOOS=darwin ./go.sh build -o out/darwin/agents-control ./cmd/agents-control" >&2; exit 1; }
[ -x "$AGENTSD" ] && [ -d "$APP" ] || { echo "no scratch build in build/DD" >&2; exit 1; }
[ -e "$ROOT" ] && { echo "$ROOT is there already: run.sh down $SLUG first" >&2; exit 1; }
mkdir -p "$ROOT/control"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT="$(free_port)"; WEB_PORT="$(free_port)"
URL="https://127.0.0.1:$PORT"
if [ "$LAN" = 1 ]; then
  ADDRESS="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  [ -n "$ADDRESS" ] || { echo "no LAN address for --lan" >&2; exit 1; }
  URL="https://$ADDRESS:$PORT"
fi
if [ "$S3" = 1 ]; then
  printf '%s\n' "AGENTS_STORE=s3://cpgo/$SLUG" AGENTS_STORE_ENDPOINT=http://127.0.0.1:9100 AGENTS_STORE_PATH_STYLE=1 \
    AWS_ACCESS_KEY_ID=spike AWS_SECRET_ACCESS_KEY=spike-secret-key AWS_REGION=us-east-1 >"$ROOT/control/store.env"
fi
if [ "$KMS" = 1 ]; then
  # The local keeper's key, beside the sealed control key: in a real set-up it would be
  # Google Cloud KMS's (gcpkms://…), and this file would not exist.
  [ -f "$ROOT/control/kek" ] || head -c 32 /dev/urandom | base64 >"$ROOT/control/kek"
  echo "AGENTS_CONTROL_KMS=base64key://$(tr '+/' '-_' <"$ROOT/control/kek" | tr -d '=\n')" >>"$ROOT/control/store.env"
fi
STORE_ENV=()
if [ -f "$ROOT/control/store.env" ]; then while read -r l; do STORE_ENV+=("$l"); done <"$ROOT/control/store.env"; fi
WEB_ARGS=()
[ "$WEB" = 1 ] && WEB_ARGS=(--web "$REPO/Web/dist" --web-port "$WEB_PORT")

"${CLEAN[@]}" ${STORE_ENV[@]+"${STORE_ENV[@]}"} AGENTS_CONTROL_URL="$URL" AGENTS_CONTROL_NAME="run-$SLUG (Go)" \
  nohup "$CONTROL" serve --home "$ROOT/control" --port "$PORT" --no-bonjour --host-root "$ROOT" ${WEB_ARGS[@]+"${WEB_ARGS[@]}"} \
  >>"$ROOT/control/control.log" 2>&1 &
echo $! >"$ROOT/control/control.pid"
for _ in $(seq 1 100); do curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
curl -sk --max-time 1 "https://127.0.0.1:$PORT/healthz" >/dev/null || { echo "the Go control plane did not answer — see $ROOT/control/control.log" >&2; tail -5 "$ROOT/control/control.log" >&2; exit 1; }
code() { "${CLEAN[@]}" ${STORE_ENV[@]+"${STORE_ENV[@]}"} "$CONTROL" code "$@" --home "$ROOT/control" | head -1; }

# Today's Swift host, as Agents Host's launch agent runs it, less this session's CLAUDE_* and AGENTS_*.
STRIP=()
for name in $(env | grep -oE '^(CLAUDE[A-Z_]*|AGENTS_[A-Z_]*)='); do STRIP+=(-u "${name%=}"); done
env ${STRIP[@]+"${STRIP[@]}"} AGENTS_ROOT="$ROOT" nohup "$AGENTSD" --control-code "$(code --host)" >"$ROOT/host.out" 2>&1 &
for _ in $(seq 1 200); do
  [ -S "$ROOT/daemon.sock" ] && grep -q "uplink: connected to the control plane" "$ROOT/logs/daemon.log" 2>/dev/null && break
  sleep 0.1
done
grep -q "uplink: connected to the control plane" "$ROOT/logs/daemon.log" 2>/dev/null \
  || { echo "the Swift host did not join — see $ROOT/logs/daemon.log" >&2; exit 1; }

APP_PID=none
if [ "$WINDOW" = 1 ]; then
  "${CLEAN[@]}" open -n -g --env AGENTS_CONTROL="$(code --client)" "$APP" --args --walk "run-$SLUG" -ApplePersistenceIgnoreState YES
  for _ in $(seq 1 100); do
    APP_PID="$(pgrep -f "Agents.app/Contents/MacOS/Agents --walk run-$SLUG( |$)" | head -1 || true)"
    [ -n "$APP_PID" ] && break; sleep 0.1
  done
fi
cat <<EOF
ROOT=$ROOT
CONTROL_URL=$URL
CONTROL_PID=$(cat "$ROOT/control/control.pid")
HOST_PID=$(tr -d '[:space:]' <"$ROOT/daemon.lock" 2>/dev/null || echo unknown)
APP_PID=${APP_PID:-none}
WEB_URL=$([ "$WEB" = 1 ] && echo "http://localhost:$WEB_PORT/" || echo none)
CONTROL_LOG=$ROOT/control/control.log
HOST_LOG=$ROOT/logs/daemon.log
EOF
