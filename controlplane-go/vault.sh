#!/bin/sh
# A Vault in dev mode, with transit, as the stand-in for a remote KMS (Google Cloud KMS, #61)
# in the spike's stage 9: container cpgo-vault, on the docker network cpgo for ./go.sh test,
# and on 127.0.0.1:19200 for a control plane run on this Mac, through the devbox's ssh as
# minio.sh does (Colima forwards no new port). Two transit keys: cpgo, and cpgo-other for a
# wrong key. The control plane gets a token of its own that can only encrypt and decrypt
# with them, never read or export them, as a service account with the KMS's
# encrypter/decrypter role would.
#   ./vault.sh up | down | env | token      env prints what ./go.sh test needs
set -e
pidfile="$HOME/Library/Caches/Agents-build/cpgo-vault-tunnel.pid"
tokenfile="$HOME/Library/Caches/Agents-build/cpgo-vault-token"
v() { docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 -e VAULT_TOKEN=spike-root cpgo-vault vault "$@"; }
case "${1:-up}" in
up)
  docker network inspect cpgo >/dev/null 2>&1 || docker network create cpgo >/dev/null
  if ! docker inspect cpgo-vault >/dev/null 2>&1; then
    docker run -d --name cpgo-vault --cap-add=IPC_LOCK -e VAULT_DEV_ROOT_TOKEN_ID=spike-root \
      -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 hashicorp/vault:latest >/dev/null
    docker network connect cpgo cpgo-vault
    for _ in $(seq 1 50); do v status >/dev/null 2>&1 && break; sleep 0.2; done
    v secrets enable transit >/dev/null
    v write -f transit/keys/cpgo >/dev/null
    v write -f transit/keys/cpgo-other >/dev/null
    printf '%s\n' 'path "transit/encrypt/cpgo*" { capabilities = ["update"] }' \
      'path "transit/decrypt/cpgo*" { capabilities = ["update"] }' | v policy write cpgo-seal - >/dev/null
    v token create -policy=cpgo-seal -field=token >"$tokenfile"
  fi
  if ! { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }; then
    ip=$(docker inspect cpgo-vault --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
    ssh -f -N -o ExitOnForwardFailure=yes -o UserKnownHostsFile="$HOME/.cache/agents-devbox/known_hosts" \
      -i "$HOME/.ssh/id_ed25519" -p 2222 -L "127.0.0.1:19200:$ip:8200" agents@127.0.0.1
    pgrep -f "127.0.0.1:19200:$ip:8200" | head -1 >"$pidfile"
  fi
  for _ in $(seq 1 50); do curl -sf http://127.0.0.1:19200/v1/sys/health >/dev/null && break; sleep 0.2; done
  curl -sf http://127.0.0.1:19200/v1/sys/health >/dev/null && echo "vault up at http://127.0.0.1:19200 (in docker: http://cpgo-vault:8200)" ;;
down)
  [ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null; rm -f "$pidfile" "$tokenfile"
  docker rm -f cpgo-vault >/dev/null 2>&1 || true ;;
token) cat "$tokenfile" ;;
env)
  echo "export GO_NETWORK=cpgo AGENTS_TEST_VAULT=http://cpgo-vault:8200 VAULT_SERVER_TOKEN=$(cat "$tokenfile")" ;;
esac
