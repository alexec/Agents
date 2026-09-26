#!/bin/bash
# rpc.py, but to a server's daemon: through the window's own forward of it.
#
#   server-rpc.sh ROOT call daemon/status
#   server-rpc.sh ROOT start claude file:///home/agents/src/hello "prompt" 90
#   server-rpc.sh ROOT watch 60 agent/changed
#
# The window forwards each connected server's daemon.sock to <ROOT>/hosts/<id>.sock.
# rpc.py wants a folder with a daemon.sock in it, so one is made next to ROOT. With more
# than one server, HOST=<id> picks (ls ROOT/hosts). A cwd on the server is a file:// URL
# of the server's path, not this Mac's.
set -euo pipefail
ROOT="${1:?usage: server-rpc.sh ROOT rpc.py-args…}"; shift
RPC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../run-app/scripts" && pwd)/rpc.py"
socks=("$ROOT"/hosts/${HOST:-*}.sock)
[ -S "${socks[0]}" ] || { echo "no forwarded server socket under $ROOT/hosts — is a server connected?" >&2; exit 1; }
[ ${#socks[@]} -eq 1 ] || { echo "more than one server; set HOST to one of: $(cd "$ROOT/hosts" && ls *.sock)" >&2; exit 1; }
LINK="$ROOT-srv"
mkdir -p "$LINK" && ln -sf "${socks[0]}" "$LINK/daemon.sock"
exec python3 "$RPC" "$LINK" "$@"
