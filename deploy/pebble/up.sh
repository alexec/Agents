#!/bin/zsh
# compose.public.yaml with Pebble for its CA, on this machine (#61): no real domain, no real
# CA. Prints the root Pebble made, which a machine has to trust for the certificate to count
# as public there; with --devbox, also puts it in the devbox's system roots, and the domain in
# its /etc/hosts.
#
#   deploy/pebble/up.sh [--devbox]
#   PEBBLE_PROFILE=renewal-walk RENEW_INTERVAL=30s deploy/pebble/up.sh    # ten-minute certificates
#   deploy/pebble/down.sh
set -euo pipefail
deploy=${0:A:h:h}
export AGENTS_DOMAIN=agents.127.0.0.1.sslip.io ACME_EMAIL=walk@example.com
compose=(docker compose -p agents-pebble -f $deploy/compose.public.yaml -f $deploy/compose.pebble.yaml)

$deploy/make-secrets.sh --public
# Pebble's ACME directory is HTTPS signed by its own test CA, which Caddy has to trust.
id=$(docker create ghcr.io/letsencrypt/pebble:latest)
docker cp -q $id:/test/certs/pebble.minica.pem $deploy/secrets/pebble-minica.pem
docker rm $id >/dev/null
$compose up -d --build
# Colima doesn't always forward a new container's ports to this Mac; its ssh does it here.
mux=~/.colima/_lima/colima/ssh.sock
if [[ -S $mux ]]; then
    for port in 8444 15000; do
        nc -z 127.0.0.1 $port 2>/dev/null || ssh -S $mux -O forward -L 127.0.0.1:$port:127.0.0.1:$port lima-colima 2>/dev/null || true
    done
fi

# The root Pebble made as it started: every certificate it issues chains to it.
root=$deploy/secrets/pebble-root.pem
for i in {1..30}; do curl -skf https://127.0.0.1:15000/roots/0 -o $root && break; sleep 1; done
[[ -s $root ]] || { print -u2 "Pebble gave no root"; exit 1 }
print -n "waiting for Caddy's certificate"
for i in {1..60}; do
    curl -sf --cacert $root https://$AGENTS_DOMAIN:8444/healthz >/dev/null && break
    print -n .; sleep 2
done
print
curl -sf --cacert $root https://$AGENTS_DOMAIN:8444/healthz >/dev/null || { print -u2 "no certificate; see: ${compose[*]} logs caddy"; exit 1 }

if [[ ${1:-} == --devbox ]]; then
    # The devbox joins the compose network, reaches Caddy by the domain, and trusts the root
    # as a system root, as a server trusts Let's Encrypt's.
    network=agents-pebble_default
    docker network connect $network agents-devbox 2>/dev/null || true
    caddy_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" agents-pebble-caddy-1)
    docker exec -u root agents-devbox sh -c "grep -v ' $AGENTS_DOMAIN\$' /etc/hosts > /tmp/hosts; echo '$caddy_ip $AGENTS_DOMAIN' >> /tmp/hosts; cat /tmp/hosts > /etc/hosts"
    docker cp -q $root agents-devbox:/usr/local/share/ca-certificates/pebble-walk.crt
    docker exec -u root agents-devbox update-ca-certificates >/dev/null
    print "devbox: $AGENTS_DOMAIN is $caddy_ip, Pebble's root is a system root"
fi
print "https://$AGENTS_DOMAIN:8444 has a certificate from Pebble; its root is $root"
