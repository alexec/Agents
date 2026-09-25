#!/bin/bash
# The Linux server the 037 walk runs against: Docker container `agents-devbox` under
# Colima, sshd on 127.0.0.1:2222 only, user `agents`, key login with ~/.ssh/id_ed25519.
#
#   devbox.sh up        start Colima and the box, building it the first time; waits for ssh
#   devbox.sh status    box, sshd, installed agentsd, running agentsd, Claude sign-in
#   devbox.sh ssh [CMD] ssh in as agents (or run CMD), without touching ~/.ssh/known_hosts
#   devbox.sh fresh     take away what the app installed (~/.agents-server), for a first install
#   devbox.sh logs      the server daemon's log
#   devbox.sh rebuild   new image and container; /home/agents is a volume and survives
#   devbox.sh down      stop the box (Colima keeps running)
#
# Host keys live in ~/.cache/agents-devbox/hostkeys and go into every image, so the box
# keeps one identity across rebuilds and the app's trusted key stays good.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=agents-devbox
PORT=2222
CACHE="$HOME/.cache/agents-devbox"
KNOWN="$CACHE/known_hosts"
SSH=(ssh -o BatchMode=yes -o UserKnownHostsFile="$KNOWN" -o GlobalKnownHostsFile=/dev/null -p $PORT agents@127.0.0.1)

colima_up() {
  docker info >/dev/null 2>&1 && return
  echo "starting colima…" >&2
  colima start >/dev/null
}

hostkeys() {
  [ -f "$CACHE/hostkeys/ssh_host_ed25519_key" ] && return
  mkdir -p "$CACHE/hostkeys"
  for t in ed25519 rsa ecdsa; do
    ssh-keygen -q -N '' -t $t -f "$CACHE/hostkeys/ssh_host_${t}_key" -C "$NAME"
  done
}

build() {
  hostkeys
  local ctx; ctx="$(mktemp -d /tmp/devbox-ctx.XXXX)"
  cp "$HERE/../devbox/Dockerfile" "$ctx/"
  cp "$HOME/.ssh/id_ed25519.pub" "$ctx/authorized_keys"
  cp -R "$CACHE/hostkeys" "$ctx/hostkeys"
  echo "building image $NAME…" >&2
  docker build -q -t $NAME "$ctx" >/dev/null
  rm -rf "$ctx"
}

known() {
  mkdir -p "$CACHE"
  printf '[127.0.0.1]:%s %s\n' $PORT "$(cut -d' ' -f1,2 "$CACHE/hostkeys/ssh_host_ed25519_key.pub")" > "$KNOWN"
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
    if ! docker container inspect $NAME >/dev/null 2>&1; then
      docker image inspect $NAME >/dev/null 2>&1 || build
      docker run -d --name $NAME --restart unless-stopped -p 127.0.0.1:$PORT:22 \
        -v $NAME-home:/home/agents $NAME >/dev/null
    else
      docker start $NAME >/dev/null
    fi
    [ -f "$CACHE/hostkeys/ssh_host_ed25519_key.pub" ] || { mkdir -p "$CACHE/hostkeys"; docker cp $NAME:/etc/ssh/ssh_host_ed25519_key.pub "$CACHE/hostkeys/"; }
    known
    wait_ssh
    echo "up: agents@127.0.0.1:$PORT"
    ;;
  status)
    docker info >/dev/null 2>&1 || { echo "docker: not running (devbox.sh up)"; exit 0; }
    docker ps -a --filter name=^$NAME\$ --format 'box: {{.Status}}'
    "${SSH[@]}" 'echo "ssh: ok ($(uname -sm))"
      if [ -f ~/.agents-server/install.json ]; then echo "installed: $(cat ~/.agents-server/install.json)"; else echo "installed: nothing"; fi
      p=$(pgrep -af "agentsd.*--serve" | grep -v pgrep); echo "agentsd: ${p:-not running}"
      echo "runtimes: $(command -v claude-agent-acp >/dev/null && echo claude-agent-acp) $(command -v claude >/dev/null && echo "claude $(claude --version 2>/dev/null | head -1)")"
      if [ -s ~/.claude/.credentials.json ]; then echo "claude sign-in: yes"; else echo "claude sign-in: NO (devbox.sh ssh, then claude, /login)"; fi' \
      2>/dev/null || echo "ssh: not answering"
    ;;
  ssh)
    shift
    if [ $# -eq 0 ]; then exec ssh -t -o UserKnownHostsFile="$KNOWN" -o GlobalKnownHostsFile=/dev/null -p $PORT agents@127.0.0.1
    else exec "${SSH[@]}" "$@"; fi
    ;;
  fresh)
    # The daemon first, by its own lock: never a pattern kill.
    "${SSH[@]}" 'p=$(cat ~/.agents-server/root/daemon.lock 2>/dev/null | tr -d "[:space:]"); [ -n "$p" ] && kill "$p" 2>/dev/null; sleep 1; rm -rf ~/.agents-server; echo "removed ~/.agents-server"'
    ;;
  logs)
    "${SSH[@]}" 'tail -n ${1:-80} ~/.agents-server/root/daemon.log'
    ;;
  rebuild)
    colima_up
    docker rm -f $NAME >/dev/null 2>&1 || true
    build
    "$0" up
    ;;
  down)
    docker stop $NAME >/dev/null && echo "stopped $NAME"
    ;;
  *)
    sed -n '2,15p' "$0"; exit 2 ;;
esac
