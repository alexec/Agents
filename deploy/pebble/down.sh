#!/bin/zsh
# Undoes deploy/pebble/up.sh: the containers and their volumes, and the devbox's trust in
# Pebble's root and its /etc/hosts line, if it was given them.
set -euo pipefail
deploy=${0:A:h:h}
export AGENTS_DOMAIN=agents.127.0.0.1.sslip.io ACME_EMAIL=walk@example.com
if docker inspect agents-devbox >/dev/null 2>&1; then
    docker exec -u root agents-devbox sh -c "grep -v ' $AGENTS_DOMAIN\$' /etc/hosts > /tmp/hosts; cat /tmp/hosts > /etc/hosts; rm -f /usr/local/share/ca-certificates/pebble-walk.crt; update-ca-certificates --fresh >/dev/null"
    docker network disconnect agents-pebble_default agents-devbox 2>/dev/null || true
fi
docker compose -p agents-pebble -f $deploy/compose.public.yaml -f $deploy/compose.pebble.yaml down -v
mux=~/.colima/_lima/colima/ssh.sock
if [[ -S $mux ]]; then
    for port in 8444 15000; do ssh -S $mux -O cancel -L 127.0.0.1:$port:127.0.0.1:$port lima-colima 2>/dev/null || true; done
fi
rm -f $deploy/secrets/pebble-root.pem $deploy/secrets/pebble-minica.pem
