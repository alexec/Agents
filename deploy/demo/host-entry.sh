#!/bin/sh
# The demo host's start (058, T092): a project to show, the host joined with its code the
# first time, and the echo runtime as the only one it can start.
set -e
project=/home/demo/Welcome
if [ ! -d "$project/.git" ]; then
  mkdir -p "$project" && cd "$project"
  git init -q
  printf '# Welcome\n\nA demo project. Start an agent here with the Demo runtime: it says back what you tell it.\n' > README.md
  git -c user.name=Demo -c user.email=demo@example.com add README.md
  git -c user.name=Demo -c user.email=demo@example.com commit -qm "Welcome"
fi
joined=""
[ -f "$AGENTS_ROOT/control-host.json" ] || joined="--control-code $(cat /codes/host)"
# shellcheck disable=SC2086
agentsd $joined --host-name "Demo host" &
daemon=$!
# The project, once the daemon answers on its socket.
for i in $(seq 1 60); do
  if printf '{"jsonrpc":"2.0","id":1,"method":"projects/add","params":{"folder":"file://%s"}}\n' "$project" \
       | nc -U -w 2 "$AGENTS_ROOT/daemon.sock" | grep -q '"result"'; then
    break
  fi
  sleep 1
done
wait $daemon
