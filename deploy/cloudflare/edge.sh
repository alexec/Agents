#!/usr/bin/env bash
# The control plane's edge settings at Cloudflare (#2151), for the zone that fronts it: SSL
# mode Full (strict), HSTS (one zone setting covers every name in it, control and views
# both), and one rate-limiting rule across the paths worth slowing a stranger on. Safe to run
# again: each setting is replaced with what this script says, not merged with one made by
# hand at Cloudflare since. Run deploy/cloudflare/dns.sh --proxied first (and wait for it to
# take), or the ranges below have no proxy to run on yet.
#
#   deploy/cloudflare/edge.sh [--dry-run] [--zone agentloops.dev]
#
# Fits Cloudflare's free plan: one rate-limiting rule, across every path below, rather than
# one each (decided, #2151; Alex can overrule, which needs a paid plan: his call, it's money).
#
# The token needs more than deploy/cloudflare/dns.sh's: Zone ▸ DNS ▸ Edit (already there),
# plus Zone ▸ Zone WAF ▸ Edit and Zone ▸ Zone Settings ▸ Edit, for this zone only. Edit the
# existing Keychain item agents-cloudflare-token at Cloudflare (My Profile ▸ API Tokens), or
# make a new one with all three, then:
#
#   security add-generic-password -a "$USER" -s agents-cloudflare-token -w -U
#
# --dry-run prints the requests and makes none: it needs no token.
set -euo pipefail
die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

dry_run=0
zone=agentloops.dev
while (($#)); do
	case $1 in
	--dry-run) dry_run=1; shift ;;
	--zone) zone=${2:?--zone needs a domain}; shift 2 ;;
	*) die "$1 is not an option" ;;
	esac
done
command -v jq >/dev/null || die "jq is needed"
api=https://api.cloudflare.com/client/v4
token=''
if ! ((dry_run)); then
	token=$(security find-generic-password -s agents-cloudflare-token -w 2>/dev/null) ||
		die "no Keychain item agents-cloudflare-token: make it as this script's head says"
fi

# cf METHOD PATH [JSON]: one API call; prints its result. The token goes in a header read from
# a file descriptor, so no process list shows it.
cf() {
	local method=$1 path=$2 body=${3:-} out
	if ((dry_run)); then
		printf '+ curl -X %s %s%s -H "Authorization: Bearer <agents-cloudflare-token>"%s\n' \
			"$method" "$api" "$path" "${body:+ --data '$body'}" >&2
		echo '{}'
		return
	fi
	local args=(-sS -X "$method" -H 'Content-Type: application/json' -H @<(printf 'Authorization: Bearer %s\n' "$token"))
	[[ -n $body ]] && args+=(--data "$body")
	out=$(curl "${args[@]}" "$api$path")
	[[ $(jq -r '.success' <<<"$out") == true ]] ||
		die "$method $path: $(jq -r '[.errors[]? | .message] | join("; ")' <<<"$out" 2>/dev/null || echo "$out")"
	jq -c '.result' <<<"$out"
}

if ((dry_run)); then
	zone_id=ZONE_ID
	cf GET "/zones?name=$zone" >/dev/null
else
	zone_id=$(cf GET "/zones?name=$zone" | jq -r '.[0].id // empty')
	[[ -n $zone_id ]] || die "the token sees no zone $zone"
fi

say() { printf '%s\n' "$*"; }

say "== SSL mode: Full (strict)"
cf PATCH "/zones/$zone_id/settings/ssl" '{"value":"strict"}' >/dev/null
say "done"

say "== HSTS (every name in $zone, control and views both)"
cf PATCH "/zones/$zone_id/settings/security_header" \
	'{"value":{"strict_transport_security":{"enabled":true,"max_age":31536000,"include_subdomains":true,"nosniff":true,"preload":false}}}' >/dev/null
say "done"

say "== rate limit: join, sign-in and the downloads (install.sh, servers, toolsets)"
# One rule, one threshold: these are all automated-abuse paths (public-security.md P3 already
# limits each in-process; this is the edge backstop over #2150, not a replacement for it). 60
# requests a minute from one address is well over what a real client or server ever sends.
expr='(http.request.uri.path eq "/v1/join") or (starts_with(http.request.uri.path, "/oauth/")) or (http.request.uri.path eq "/v1/install.sh") or (starts_with(http.request.uri.path, "/v1/servers/")) or (starts_with(http.request.uri.path, "/v1/toolsets/"))'
rule=$(jq -n --arg expr "$expr" '{
	rules: [{
		action: "block",
		description: "control plane: join, sign-in and downloads (#2151)",
		expression: $expr,
		ratelimit: {
			characteristics: ["ip.src"],
			period: 60,
			requests_per_period: 60,
			mitigation_timeout: 60
		}
	}]
}')
cf PUT "/zones/$zone_id/rulesets/phases/http_ratelimit/entrypoint" "$rule" >/dev/null
say "done"
