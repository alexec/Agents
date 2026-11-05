#!/usr/bin/env bash
# Walks a generic OIDC org provider on a real issuer (#3415): Dex in a container, with a
# certificate of its own, a client for the control plane and one person, then
# TestOrgSignInLiveIssuer in a golang container on the same network, which starts a
# scratch control plane, adds Dex as a provider and signs in through Dex's password form.
# Everything it starts, it stops and removes, also when the walk fails. Lease "build" first.
#
#   scripts/oidc-walk.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
dex_image=${DEX_IMAGE:-ghcr.io/dexidp/dex:v2.44.0}
go_image=${GO_IMAGE:-golang:1.26}
tag=agents-oidc-walk-$$
cache="${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}"
# Under the home folder, which Colima shares with its VM; /tmp and $TMPDIR it does not.
mkdir -p "$cache/go/gopath" "$cache/go/gocache"
dir=$(mktemp -d "$cache/$tag.XXXXXX")
port=8791
secret=$(openssl rand -hex 16)

cleanup() {
	docker rm -f "$tag-dex" >/dev/null 2>&1 || true
	docker network rm "$tag" >/dev/null 2>&1 || true
	rm -rf "$dir"
}
trap cleanup EXIT

# Dex's certificate, for the name the network gives it; the test trusts it as a root.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=dex -addext subjectAltName=DNS:dex \
	-keyout "$dir/dex.key" -out "$dir/dex.crt" 2>/dev/null
chmod 644 "$dir/dex.key"

# The password is "password" (Dex's example hash).
cat >"$dir/config.yaml" <<EOF
issuer: https://dex:5556/dex
storage:
  type: memory
web:
  https: 0.0.0.0:5556
  tlsCert: /cfg/dex.crt
  tlsKey: /cfg/dex.key
oauth2:
  skipApprovalScreen: true
enablePasswordDB: true
staticClients:
  - id: agents-control
    name: Agents
    secret: $secret
    redirectURIs: ["http://127.0.0.1:$port/v1/oidc/callback"]
staticPasswords:
  - email: sam@example.com
    hash: "\$2a\$10\$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
    username: Sam
    userID: 08a8684b-db88-4b73-90a9-3cd1661f5466
EOF

docker network create "$tag" >/dev/null
docker run -d --name "$tag-dex" --network "$tag" --network-alias dex -v "$dir":/cfg:ro \
	"$dex_image" dex serve /cfg/config.yaml >/dev/null

status=0
docker run --rm --network "$tag" -v "$repo":/repo -v "$cache/go/gopath":/go -v "$cache/go/gocache":/root/.cache/go-build \
	-e CGO_ENABLED=0 \
	-e AGENTS_LIVE_OIDC_ISSUER=https://dex:5556/dex \
	-e AGENTS_LIVE_OIDC_TRUST_ROOT="$(cat "$dir/dex.crt")" \
	-e AGENTS_LIVE_OIDC_CLIENT_ID=agents-control \
	-e AGENTS_LIVE_OIDC_CLIENT_SECRET="$secret" \
	-e AGENTS_LIVE_OIDC_LOGIN=sam@example.com \
	-e AGENTS_LIVE_OIDC_PASSWORD=password \
	-e AGENTS_LIVE_OIDC_PORT=$port \
	-w /repo/Go "$go_image" go test -count=1 -v -run '^TestOrgSignInLiveIssuer$' ./internal/controlplane/ || status=$?

if [ "$status" -ne 0 ]; then
	echo "--- Dex's log" >&2
	docker logs "$tag-dex" 2>&1 | tail -40 >&2
fi
exit "$status"
