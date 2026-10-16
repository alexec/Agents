#!/bin/sh
# Builds the Go host for the devbox, copies it there and restarts it on its own root
# (~/.agents-go/root), by the pid in that root's daemon.lock: never a pattern kill.
#   ./devbox.sh                 build, copy, restart (the root's membership is kept)
#   ./devbox.sh join '<code>'   the same, enrolling afresh with a host code
#   ./devbox.sh log             the host's daemon.log
set -e
here=$(cd "$(dirname "$0")" && pwd)
ssh_() { ssh -p 2222 -o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" -i "$HOME/.ssh/id_ed25519" agents@127.0.0.1 "$@"; }
case "$1" in
log) ssh_ 'tail -n 80 ~/.agents-go/root/daemon.log'; exit ;;
esac
"$here/go.sh" build -trimpath -ldflags "-s -w" -o out/agentsd-linux-arm64 ./cmd/agentsd
scp -q -P 2222 -o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" -i "$HOME/.ssh/id_ed25519" \
  "$here/out/agentsd-linux-arm64" agents@127.0.0.1:/home/agents/agentsd-go.new
join=""
if [ "$1" = join ]; then join="--control '$2'"; fi
ssh_ "set -e; R=\$HOME/.agents-go/root; if [ -f \$R/daemon.lock ]; then kill \$(cat \$R/daemon.lock) 2>/dev/null || true; sleep 1; fi
  mv ~/agentsd-go.new ~/agentsd-go; chmod 700 ~/agentsd-go
  [ -n \"$join\" ] && rm -f \$R/control-host.json
  AGENTS_MACHINE_ID=go-devbox ~/agentsd-go --root \$R --serve --detach --control-network $join --host-name 'devbox (Go)'
  sleep 2; tail -n 5 \$R/daemon.log"
