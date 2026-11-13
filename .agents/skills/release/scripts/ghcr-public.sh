#!/usr/bin/env bash
# Is the control plane's image public on GHCR? (#5066)
#
#   .agents/skills/release/scripts/ghcr-public.sh [OWNER/NAME]
#
# The live control plane's VM pulls the release's image with no credential (deploy/gcp/up.sh), so
# the package must be public. This asks GHCR as a stranger: an anonymous pull token, then
# /v2/<owner>/<name>/tags/list. It changes nothing.
#
# OWNER/NAME defaults to <the origin repo's owner>/agents-control, the name release.yml pushes
# (ghcr.io/${{ github.repository_owner }}/agents-control, #4929).
#
# Exit 0: public (it prints the newest tags). Exit 1: not public, or no such package; a private
# package and a missing one look the same to a stranger. Exit 2: GHCR or the network failed.
set -euo pipefail
say() { printf 'ghcr-public: %s\n' "$*" >&2; }

package=${1:-}
if [[ -z $package ]]; then
	owner=$(gh repo view --json owner --jq .owner.login 2>/dev/null) || {
		say "give OWNER/NAME: gh could not say the origin repo's owner"
		exit 2
	}
	package=$(tr '[:upper:]' '[:lower:]' <<<"$owner")/agents-control
fi
[[ $package =~ ^[a-z0-9._-]+/[a-z0-9._/-]+$ ]] || {
	say "$package is not OWNER/NAME in lower case"
	exit 2
}

# The anonymous token: GHCR gives one for any repository; it lets a pull through only when the
# package is public.
body=$(curl -sS --max-time 20 "https://ghcr.io/token?scope=repository:$package:pull") || {
	say "ghcr.io did not answer the token request"
	exit 2
}
token=$(jq -r '.token // empty' <<<"$body" 2>/dev/null || true)
[[ -n $token ]] || {
	say "ghcr.io gave no anonymous token for $package: not public, or no such package"
	exit 1
}

out=$(mktemp)
trap 'rm -f "$out"' EXIT
code=$(curl -sS --max-time 20 -o "$out" -w '%{http_code}' \
	-H "Authorization: Bearer $token" "https://ghcr.io/v2/$package/tags/list") || {
	say "ghcr.io did not answer the tags request"
	exit 2
}
case $code in
200)
	say "ghcr.io/$package is public; newest tags: $(jq -r '.tags // [] | .[-5:] | join(" ")' "$out")"
	exit 0
	;;
401 | 403 | 404)
	say "ghcr.io/$package is not public, or there is no such package (HTTP $code)"
	exit 1
	;;
*)
	say "ghcr.io answered HTTP $code for $package"
	exit 2
	;;
esac
