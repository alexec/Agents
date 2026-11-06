#!/usr/bin/env bash
# Walks Okta as an org provider and a SCIM client on a real Okta org (#3415): a Cloudflare
# quick tunnel (a public https URL, for as long as the walk runs) to TestOktaLive in a
# golang container on the same network, which starts a scratch control plane with an
# in-memory store. Okta's sign-in and its SCIM client reach the plane through the tunnel.
# Opening the tunnel needs Alex's approval (a form) each time.
#
# The person who walks it drives a browser and Okta's admin console, and talks to the test
# through files in the folder it prints (TestOktaLive says which). Everything it starts, it
# stops and removes, also when the walk fails; the folder stays, with scim.jsonl, until
# the walker deletes it. Lease "build" first.
#
#   scripts/okta-walk.sh
#
# The walk, once the folder has start-1: `scripts/okta-signin.mjs <dir>/start-1 <dir>/ticket-1`
# in the sign-up skill's private Chrome (then start-2, in a fresh one); scim-url and
# scim-token into the SCIM app's Provisioning tab (Test API Credentials, Save); assign,
# change, push a group and deactivate in Okta; then write the deactivated userName to
# <dir>/done. scim.jsonl is Okta's request set (scim/testdata/okta.json was made from it).
#
# ~/.agents/secrets/okta-integrator holds OKTA_ORG_URL, OKTA_CLIENT_ID and
# OKTA_CLIENT_SECRET: the Okta app whose sign-in redirect URI is <tunnel>/v1/oidc/callback.
# The tunnel's name is new each run: with OKTA_API_TOKEN and OKTA_APP_ID there too, the
# script sets that URI itself; without them, the walker sets it when the script prints it
# and touches the folder's file "ready".
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tunnel_image=${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:2026.10.7}
go_image=${GO_IMAGE:-golang:1.26}
secrets=${OKTA_SECRETS:-$HOME/.agents/secrets/okta-integrator}
tag=agents-okta-walk-$$
cache="${AGENTS_BUILD_CACHE:-$HOME/Library/Caches/Agents-build}"
# Under the home folder, which Colima shares with its VM; /tmp and $TMPDIR it does not.
mkdir -p "$cache/go/gopath" "$cache/go/gocache"
dir=$(mktemp -d "$cache/$tag.XXXXXX")
chmod 700 "$dir"

cleanup() {
	docker rm -f "$tag-tunnel" >/dev/null 2>&1 || true
	docker network rm "$tag" >/dev/null 2>&1 || true
	rm -f "$dir/scim-token"
}
trap cleanup EXIT

# shellcheck source=/dev/null
. "$secrets"
: "${OKTA_ORG_URL:?not in $secrets}" "${OKTA_CLIENT_ID:?not in $secrets}" "${OKTA_CLIENT_SECRET:?not in $secrets}"

docker network create "$tag" >/dev/null
docker run -d --name "$tag-tunnel" --network "$tag" "$tunnel_image" \
	tunnel --no-autoupdate --url http://walk:8790 >/dev/null
url=
for _ in $(seq 60); do
	url=$(docker logs "$tag-tunnel" 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1 || true)
	[ -n "$url" ] && break
	sleep 1
done
[ -n "$url" ] || { echo "okta-walk: the tunnel gave no URL" >&2; docker logs "$tag-tunnel" >&2; exit 1; }
echo "okta-walk: folder $dir"
if [ -n "${OKTA_API_TOKEN:-}" ] && [ -n "${OKTA_APP_ID:-}" ]; then
	# The app's sign-in redirect URI, by Okta's apps API: a GET, the URI changed, a PUT.
	curl -fsS -H "Authorization: SSWS $OKTA_API_TOKEN" -H 'Accept: application/json' "$OKTA_ORG_URL/api/v1/apps/$OKTA_APP_ID" |
		REDIRECT="$url/v1/oidc/callback" python3 -c 'import json, os, sys
d = json.load(sys.stdin)
d["settings"]["oauthClient"]["redirect_uris"] = [os.environ["REDIRECT"]]
d["credentials"]["oauthClient"].pop("client_secret", None)
json.dump(d, sys.stdout)' >"$dir/app.json"
	curl -fsS -o /dev/null -X PUT -H "Authorization: SSWS $OKTA_API_TOKEN" -H 'Content-Type: application/json' \
		-H 'Accept: application/json' "$OKTA_ORG_URL/api/v1/apps/$OKTA_APP_ID" -d @"$dir/app.json"
	rm -f "$dir/app.json"
	echo "okta-walk: tunnel $url; the app's sign-in redirect URI is $url/v1/oidc/callback"
else
	echo "okta-walk: tunnel $url; set the app's sign-in redirect URI to $url/v1/oidc/callback, then touch $dir/ready"
	until [ -e "$dir/ready" ]; do sleep 1; done
fi

# The secret passes by name, from this environment, so it is on no command line.
export AGENTS_LIVE_OKTA_CLIENT_SECRET="$OKTA_CLIENT_SECRET"
status=0
docker run --rm --name "$tag-walk" --network "$tag" --network-alias walk -v "$repo":/repo -v "$dir":/walk \
	-v "$cache/go/gopath":/go -v "$cache/go/gocache":/root/.cache/go-build \
	-e CGO_ENABLED=0 \
	-e AGENTS_LIVE_OKTA_ORG="$OKTA_ORG_URL" \
	-e AGENTS_LIVE_OKTA_URL="$url" \
	-e AGENTS_LIVE_OKTA_CLIENT_ID="$OKTA_CLIENT_ID" \
	-e AGENTS_LIVE_OKTA_CLIENT_SECRET \
	-e AGENTS_LIVE_OKTA_DIR=/walk \
	-w /repo/Go "$go_image" go test -count=1 -v -timeout 90m -run '^TestOktaLive$' ./internal/controlplane/ || status=$?
exit "$status"
