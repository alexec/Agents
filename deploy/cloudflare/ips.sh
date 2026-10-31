#!/usr/bin/env bash
# Cloudflare's published IPv4 and IPv6 ranges (#2151), one per line: the only peers that may
# reach a machine Cloudflare fronts. deploy/gcp/up.sh --cloudflare uses this for the GCP
# firewall; deploy/Caddyfile.public's own copy, for Caddy's trusted_proxies, is static (Caddy's
# stock image can't fetch a URL at start), so update both if Cloudflare ever changes this list.
#
#   deploy/cloudflare/ips.sh [--dry-run] [-4]
#
# -4 prints the IPv4 ranges only (deploy/gcp/up.sh's firewall: the VM has no IPv6).
# --dry-run prints a stand-in list and reaches no network.
set -euo pipefail
die() {
	printf '%s: %s\n' "${0##*/}" "$*" >&2
	exit 1
}

dry_run=0
v4_only=0
while (($#)); do
	case $1 in
	--dry-run) dry_run=1; shift ;;
	-4) v4_only=1; shift ;;
	-*) die "$1 is not an option" ;;
	*) die "$1: this takes no other argument" ;;
	esac
done

if ((dry_run)); then
	echo 203.0.113.0/24
	((v4_only)) || echo 2001:db8::/32
	exit 0
fi

curl -fsS https://www.cloudflare.com/ips-v4 || die "could not fetch Cloudflare's IPv4 ranges"
((v4_only)) || curl -fsS https://www.cloudflare.com/ips-v6 || die "could not fetch Cloudflare's IPv6 ranges"
