#!/bin/bash
# rpc.py, but to a server's daemon: over an ssh forward of its daemon.sock of our own.
#
#   server-rpc.sh ROOT call daemon/status
#   server-rpc.sh ROOT start claude file:///home/agents/src/hello "prompt" 90
#   server-rpc.sh ROOT watch 60 agent/changed
#
# Since 058 the window reaches a server only through the control plane, so there is no
# forwarded socket under ROOT to borrow. This makes one in ROOT-srv/ with the box's own
# ssh (BOX=devbox, the default, on 2222; BOX=bare on 2223), once, and leaves the forward
# running in the background: `server-rpc.sh ROOT --stop` ends it. A cwd on the server is a
# file:// URL of the server's path, not this Mac's.
set -euo pipefail
ROOT="${1:?usage: server-rpc.sh ROOT rpc.py-args… | --stop}"; shift
RPC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../run-app/scripts" && pwd)/rpc.py"
LINK="$ROOT-srv"
SOCK="$LINK/daemon.sock"
case "${BOX:-devbox}" in
  devbox) OPTS=(-o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" -o GlobalKnownHostsFile=/dev/null -p 2222) ;;
  bare)   OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
                -o GlobalKnownHostsFile=/dev/null -p 2223) ;;
  *) echo "BOX is devbox or bare" >&2; exit 2 ;;
esac
CONTROL=(-o ControlPath="$LINK/ssh.ctl")

if [ "${1:-}" = "--stop" ]; then
  ssh "${CONTROL[@]}" -O exit agents@127.0.0.1 2>/dev/null || true
  rm -rf "$LINK"
  exit 0
fi

if ! ssh "${CONTROL[@]}" -O check agents@127.0.0.1 2>/dev/null; then
  mkdir -p "$LINK"
  rm -f "$SOCK"
  ssh -o BatchMode=yes "${OPTS[@]}" "${CONTROL[@]}" -M -f -N -o ExitOnForwardFailure=yes \
    -L "$SOCK:/home/agents/.agents-server/root/daemon.sock" agents@127.0.0.1 \
    || { echo "could not forward the server's daemon.sock — has the server joined? (devbox.sh status)" >&2; exit 1; }
fi
exec python3 "$RPC" "$LINK" "$@"
