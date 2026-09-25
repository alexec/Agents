#!/bin/bash
# The bare Linux server the 043 walk runs against: Docker container `agents-bare` under
# Colima, sshd on 127.0.0.1:2223 only, user `agents`, key login with ~/.ssh/id_ed25519.
# Nothing else is on it: no Node, no Claude, no sign-in, and no volume.
#
#   bare.sh up        start the box, building the image the first time; waits for ssh
#   bare.sh status    box, installed agentsd and Claude toolset, running agentsd
#   bare.sh ssh [CMD] ssh in as agents (or run CMD), trusting whatever key it has now
#   bare.sh rebuild   throw the box away and start a new one: blank disk, new host key
#   bare.sh down      stop and remove the box
#
# In the app, type `agents@127.0.0.1:2223`. The app checks the key against
# ~/.ssh/known_hosts like any server; this script keeps its own list so it never touches that.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=agents-bare
PORT=2223
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o GlobalKnownHostsFile=/dev/null -p $PORT agents@127.0.0.1)

colima_up() {
  docker info >/dev/null 2>&1 && return
  echo "starting colima…" >&2
  colima start >/dev/null
}

build() {
  local ctx; ctx="$(mktemp -d /tmp/bare-ctx.XXXX)"
  cp "$HERE/../bare/Dockerfile" "$ctx/"
  cp "$HOME/.ssh/id_ed25519.pub" "$ctx/authorized_keys"
  echo "building image ${NAME}…" >&2
  docker build -q -t $NAME "$ctx" >/dev/null
  rm -rf "$ctx"
}

wait_ssh() {
  for _ in $(seq 1 50); do
    "${SSH[@]}" true 2>/dev/null && return
    sleep 0.2
  done
  echo "ssh to $NAME is not answering; docker logs $NAME" >&2
  exit 1
}

case "${1:-status}" in
  up)
    colima_up
    docker image inspect $NAME >/dev/null 2>&1 || build
    if docker container inspect $NAME >/dev/null 2>&1; then docker start $NAME >/dev/null
    else docker run -d --name $NAME -p 127.0.0.1:$PORT:22 $NAME >/dev/null; fi
    wait_ssh
    echo "up: agents@127.0.0.1:$PORT ($(docker exec $NAME ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f2))"
    ;;
  status)
    docker ps -a --filter name=^$NAME\$ --format 'box: {{.Status}}'
    "${SSH[@]}" 'echo "ssh: ok ($(uname -sm))"
      echo "node: $(command -v node || echo none)  npx: $(command -v npx || echo none)  claude sign-in: $([ -e ~/.claude ] && echo yes || echo none)"
      if [ -f ~/.agents-server/install.json ]; then echo "agentsd installed: $(cat ~/.agents-server/install.json)"; else echo "agentsd installed: nothing"; fi
      echo "claude toolset: $(readlink ~/.agents-server/tools/claude/current 2>/dev/null || echo none)"
      p=$(pgrep -af "agentsd.*--serve" | grep -v pgrep); echo "agentsd: ${p:-not running}"' \
      2>/dev/null || echo "ssh: not answering"
    ;;
  ssh)
    shift
    if [ $# -eq 0 ]; then exec ssh -t -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p $PORT agents@127.0.0.1
    else exec "${SSH[@]}" "$@"; fi
    ;;
  rebuild)
    colima_up
    docker rm -f $NAME >/dev/null 2>&1 || true
    "$0" up
    ;;
  down)
    docker rm -f $NAME >/dev/null && echo "removed $NAME"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 2 ;;
esac
