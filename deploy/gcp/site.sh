#!/usr/bin/env bash
# Our own site on the control plane's VM (#1343): the hand-back page for sign-ins at
# https://oauth.agentloops.dev/oauth/callback (deploy/site), not the apex, which is the
# promotional site (#3042). It copies deploy/site, Caddyfile.public and compose.public.yaml to
# /opt/agents on the VM, turns the site on (deploy/site.d/site.caddy and AGENTS_SITE_DOMAIN in
# deploy/.env), and starts Caddy again. The control plane is not built, copied or restarted.
#
#   deploy/gcp/site.sh [--dry-run] [--site-domain oauth.agentloops.dev]
#
# The name must point at the VM first: deploy/cloudflare/dns.sh --names oauth IP. Caddy then gets
# its certificate from Let's Encrypt. --dry-run prints every command and runs none.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=deploy/gcp/common.sh
. "$here/common.sh"

site_domain=oauth.agentloops.dev
while (($#)); do
	case $1 in
	--dry-run) dry_run=1; shift ;;
	--site-domain) site_domain=${2:?--site-domain needs a name}; shift 2 ;;
	*) die "$1 is not an option" ;;
	esac
done
setup

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/deploy/site.d"
cp "$root/deploy/compose.public.yaml" "$root/deploy/Caddyfile.public" "$stage/deploy/"
cp -R "$root/deploy/site" "$stage/deploy/site"
cp "$root/deploy/site/site.caddy" "$stage/deploy/site.d/site.caddy"
# The one line of .env it sets; the others stay as they are.
install="set -e; cd /opt/agents && sudo tar --no-same-owner -xzf -; cd deploy
sudo touch .env; sudo chmod 600 .env
{ sudo grep -v '^AGENTS_SITE_DOMAIN=' .env || true; echo 'AGENTS_SITE_DOMAIN=$site_domain'; } | sudo tee .env.t >/dev/null; sudo mv .env.t .env
cd /opt/agents && sudo docker compose -f deploy/compose.public.yaml up -d --no-build --force-recreate caddy"
say "== deploy/site on the VM, and Caddy started again"
if ((dry_run)); then
	say "+ tar -C STAGE -czf - deploy | $(shown gcloud compute ssh "$name" --zone "$zone" --quiet --command "$install")"
else
	COPYFILE_DISABLE=1 tar --no-xattrs -C "$stage" -czf - deploy | vm_ssh "$install"
fi

if ((dry_run)); then
	say "? curl -fsS https://$site_domain/oauth/callback   (until it answers)"
	exit 0
fi
printf 'waiting for the certificate'
for _ in $(seq 1 60); do
	curl -fsS "https://$site_domain/oauth/callback" >/dev/null 2>&1 && break
	printf .
	sleep 2
done
say
curl -fsS "https://$site_domain/oauth/callback" >/dev/null ||
	die "https://$site_domain/oauth/callback does not answer: see gcloud compute ssh $name --zone $zone --command 'cd /opt/agents && sudo docker compose -f deploy/compose.public.yaml logs caddy'"
say "https://$site_domain/oauth/callback is up."
