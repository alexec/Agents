#!/usr/bin/env bash
# The A records for the control plane's names (#1461, #1484), at Cloudflare's DNS: the
# page's name and the views name, both to the VM's address that deploy/gcp/up.sh prints. The
# name @ is the zone itself, kept free for the promotional site (#3042); --names oauth points
# oauth.agentloops.dev at the VM, for the hand-back page (#1343, deploy/gcp/site.sh).
# --cname TARGET makes CNAME records to TARGET instead of A records: --names docs --cname
# alexec.github.io serves the docs site from GitHub Pages at docs.agentloops.dev (#1549).
# A record that is already right is left alone, and one with another address is changed, so
# running it again is safe.
#
#   deploy/cloudflare/dns.sh [--dry-run] [--zone agentloops.dev] [--names "control views"] IP
#   deploy/cloudflare/dns.sh [--dry-run] [--zone agentloops.dev] --names docs --cname alexec.github.io
#
# The API token comes from the Keychain item agents-cloudflare-token, and is never printed or
# put on a command line. Make it at Cloudflare (My Profile ▸ API Tokens ▸ Create Token, the
# "Edit zone DNS" template, for this zone only), then:
#
#   security add-generic-password -a "$USER" -s agents-cloudflare-token -w
#
# The records are DNS only (not proxied): Caddy on the VM gets the certificates from Let's
# Encrypt, and each client checks Caddy's certificate itself. GitHub Pages also gets its own
# certificate, so a CNAME is DNS only too. --dry-run prints the requests and
# makes none: it needs no token.
set -euo pipefail
die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

dry_run=0
zone=agentloops.dev
names='control views'
ip=''
cname=''
while (($#)); do
	case $1 in
	--dry-run) dry_run=1; shift ;;
	--zone) zone=${2:?--zone needs a domain}; shift 2 ;;
	--names) names=${2:?--names needs the names, such as "control views"}; shift 2 ;;
	--cname) cname=${2:?--cname needs the target, such as alexec.github.io}; shift 2 ;;
	-*) die "$1 is not an option" ;;
	*) ip=$1; shift ;;
	esac
done
[[ -n $cname || $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "say the VM's IPv4 address: deploy/cloudflare/dns.sh [--dry-run] IP"
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
		echo '[]'
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

for n in $names; do
	fqdn=$n.$zone
	[[ $n == @ ]] && fqdn=$zone
	records=$(cf GET "/zones/$zone_id/dns_records?name=$fqdn")
	if [[ -n $cname ]]; then
		if [[ $(jq '[.[] | select(.type == "A" or .type == "AAAA")] | length' <<<"$records") != 0 ]]; then
			die "$fqdn has an A or AAAA record at Cloudflare: delete it there, then run this again"
		fi
		c=$(jq -c '[.[] | select(.type == "CNAME")]' <<<"$records")
		if [[ $(jq length <<<"$c") == 0 ]]; then
			cf POST "/zones/$zone_id/dns_records" \
				"{\"type\":\"CNAME\",\"name\":\"$fqdn\",\"content\":\"$cname\",\"ttl\":300,\"proxied\":false}" >/dev/null
			echo "$fqdn: CNAME $cname, made"
		elif [[ $(jq -r '.[0].content' <<<"$c") == "$cname" && $(jq -r '.[0].proxied' <<<"$c") == false ]]; then
			echo "$fqdn: CNAME $cname, already"
		else
			cf PATCH "/zones/$zone_id/dns_records/$(jq -r '.[0].id' <<<"$c")" \
				"{\"content\":\"$cname\",\"proxied\":false}" >/dev/null
			echo "$fqdn: CNAME $cname, changed from $(jq -r '.[0].content' <<<"$c")"
		fi
		continue
	fi
	if [[ $(jq '[.[] | select(.type == "CNAME")] | length' <<<"$records") != 0 ]]; then
		die "$fqdn is a CNAME at Cloudflare: delete it there, then run this again"
	fi
	if [[ $(jq '[.[] | select(.type == "AAAA")] | length' <<<"$records") != 0 ]]; then
		printf '%s has an AAAA record, and the VM has no IPv6: Let'\''s Encrypt tries IPv6 first, so delete it at Cloudflare.\n' "$fqdn" >&2
	fi
	a=$(jq -c '[.[] | select(.type == "A")]' <<<"$records")
	case $(jq length <<<"$a") in
	0)
		cf POST "/zones/$zone_id/dns_records" \
			"{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":300,\"proxied\":false}" >/dev/null
		echo "$fqdn: A $ip, made"
		;;
	1)
		if [[ $(jq -r '.[0].content' <<<"$a") == "$ip" && $(jq -r '.[0].proxied' <<<"$a") == false ]]; then
			echo "$fqdn: A $ip, already"
		else
			cf PATCH "/zones/$zone_id/dns_records/$(jq -r '.[0].id' <<<"$a")" \
				"{\"content\":\"$ip\",\"proxied\":false}" >/dev/null
			echo "$fqdn: A $ip, changed from $(jq -r '.[0].content' <<<"$a")"
		fi
		;;
	*) die "$fqdn has more than one A record: keep one at Cloudflare, then run this again" ;;
	esac
done
first=${names%% *}.$zone
[[ ${names%% *} == @ ]] && first=$zone
((dry_run)) || echo "Check: dig +short $first @1.1.1.1 (it can take a few minutes)"
