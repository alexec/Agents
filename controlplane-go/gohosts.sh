#!/bin/bash
# The #1125 spike's Go agentsd as two more hosts of a run.sh set-up (#1126 stage 3): one on
# this Mac on a root of its own (/tmp/run-<slug>-g), one on the agents-devbox container in
# ~/.agents-cpgo/root. The #1125 lane's own host on the box (~/.agents-go/root) is left
# alone; only the runtimes it installed in ~/.agents-go/tools are shared.
#
#   controlplane-go/gohosts.sh build              the Go agentsd and agentsctl, from the #1125 worktree
#   controlplane-go/gohosts.sh up [slug]          the set-up must be run.sh up <slug> --lan
#   controlplane-go/gohosts.sh down [slug]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
SRC="$here/../../do-spike-github-issue/agentsd-go"      # the #1125 worktree, beside this one
COPY="$HOME/Library/Caches/Agents-build/cpgo-agentsd-go" # built from a copy, so nothing there changes
G="$COPY/out"
KH="$HOME/.cache/agents-devbox/known_hosts"
box() { ssh -p 2222 -o UserKnownHostsFile="$KH" -i "$HOME/.ssh/id_ed25519" agents@127.0.0.1 "$@"; }
cmd="${1:-up}"; SLUG="${2:-cpgo}"
R="/tmp/run-$SLUG-g"

case "$cmd" in
build)
  rm -rf "$COPY" && cp -R "$SRC" "$COPY" && rm -rf "$COPY/out"
  ( cd "$COPY" && GOOS=darwin ./go.sh build -o out/darwin/agentsd ./cmd/agentsd \
      && GOOS=darwin ./go.sh build -o out/darwin/agentsctl ./cmd/agentsctl \
      && ./go.sh build -trimpath -ldflags "-s -w" -o out/agentsd-linux-arm64 ./cmd/agentsd )
  ls -l "$G/darwin" "$G/agentsd-linux-arm64" ;;
up)
  grep -q "https://192\|https://10\.\|https://172\." <(grep -o 'for https://[^ ]*' "/tmp/run-$SLUG/control/control.log") \
    || { echo "run.sh up $SLUG --lan first: the box can't reach 127.0.0.1" >&2; exit 1; }
  mkdir -p "$R"
  STRIP=(); for name in $(env | grep -oE '^(CLAUDE[A-Z_]*|AGENTS_[A-Z_]*)='); do STRIP+=(-u "${name%=}"); done
  env "${STRIP[@]}" AGENTS_ROOT="$R" AGENTS_MACHINE_ID="$SLUG-go-mac" nohup "$G/darwin/agentsd" --root "$R" --serve \
    --control-code "$("$here/run.sh" code "$SLUG" --host)" --host-name "This Mac (Go host)" >"$R/host.out" 2>&1 &
  scp -q -P 2222 -o UserKnownHostsFile="$KH" -i "$HOME/.ssh/id_ed25519" "$G/agentsd-linux-arm64" agents@127.0.0.1:/home/agents/agentsd-cpgo
  box "set -e; R=\$HOME/.agents-cpgo/root; if [ -f \$R/daemon.lock ]; then kill \$(cat \$R/daemon.lock) 2>/dev/null || true; sleep 1; fi
    rm -rf \$R; mkdir -p \$R \$HOME/src/cpgo; chmod 700 ~/agentsd-cpgo
    AGENTS_MACHINE_ID=$SLUG-devbox ~/agentsd-cpgo --root \$R --serve --detach --control-code '$("$here/run.sh" code "$SLUG" --host)' --host-name 'devbox (Go host)' >/dev/null
    sleep 2; grep uplink \$R/daemon.log | tail -1"
  for _ in $(seq 1 50); do grep -q "uplink: connected" "$R/daemon.log" 2>/dev/null && break; sleep 0.2; done
  grep uplink "$R/daemon.log" | tail -1 ;;
down)
  [ -f "$R/daemon.lock" ] && P="$(cat "$R/daemon.lock")" && ps -o command= -p "$P" | grep -q agentsd && kill "$P" || true
  rm -rf "$R"
  box 'R=$HOME/.agents-cpgo/root; [ -f $R/daemon.lock ] && kill $(cat $R/daemon.lock) 2>/dev/null; rm -rf $HOME/.agents-cpgo $HOME/agentsd-cpgo; echo "box: stopped"' ;;
*) echo "say build, up or down" >&2; exit 2 ;;
esac
