#!/usr/bin/env bash
# The hosted service on a Google Cloud VM (#2226, spec 1003 FR-040), as deploy/gcp/up.sh does
# for the control plane: deploy/compose.hosted.yaml, agents-hosted and Caddy, from nothing to
# https://$AGENTS_HOSTED_DOMAIN. Each step first looks for what it makes, so running it again
# is safe, and carries on where it stopped. The runbook is docs/how-to/run-the-hosted-service.md.
#
#   deploy/gcp/hosted-up.sh [--check] [--dry-run]
#
# It reads everything from the environment, so no secret is on a command line:
#
#   AGENTS_GCP_PROJECT              the Google Cloud project
#   AGENTS_GCP_ZONE                 the VM's zone, such as us-west1-b
#   AGENTS_GCP_KEY_FILE             the service account key it acts as
#                                   (~/.agents/secrets/gcp-agents-hosted.json)
#   AGENTS_HOSTED_DOMAIN            the sign-up pages' name, such as agentloops.dev
#   AGENTS_HOSTED_ACCOUNTS_DOMAIN   the control planes' names are <account>. this
#   AGENTS_HOSTED_GITHUB_SECRET     the GitHub App's client secret
#   ACME_EMAIL                      the address Let's Encrypt writes to
#
# and, when set, passes these on to the service: AGENTS_HOSTED_GITHUB_CLIENT_ID, the sign-up
# settings and limits (AGENTS_HOSTED_SIGNUP, AGENTS_HOSTED_MAX_ACCOUNTS, …), and billing's
# AGENTS_HOSTED_STRIPE_KEY, AGENTS_HOSTED_STRIPE_PRICE and AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET
# (all three, or none). AGENTS_HOSTED_MACHINE_TYPE (e2-medium) and AGENTS_HOSTED_DISK_GB (50)
# size the VM.
#
# With any of them missing it says each, and exits having made nothing. --check stops there.
# --dry-run prints every command and runs none: it needs no gcloud and no key file.
#
# What it makes, in the project:
# - Compute Engine, Cloud KMS and IAM turned on;
# - the Cloud KMS key "hosted" in the key ring "agents" (global), which seals every account's
#   control key;
# - the service account agents-hosted-vm, which may only encrypt and decrypt with that key;
# - the network agents-hosted, with 80 and 443 open to all and 22 only to this machine;
# - the static IPv4 address agents-hosted, and the VM agents-hosted (Debian, a standard disk),
#   with deploy/gcp/startup.sh to put Docker on it;
# - the snapshot schedule agents-hosted-daily on its disk: a snapshot each day, kept 7 days
#   (as #2136 does for the control plane). The store is on the disk, so a snapshot keeps every
#   account; `agents-hosted admin backup` keeps one.
#
# Then it stops until both names point at the VM (Let's Encrypt allows only a few failed
# tries an hour). Run it again after that: it builds the image here, copies it and the
# compose file to /opt/agents on the VM, and starts the service.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=deploy/gcp/common.sh
. "$here/common.sh"

check_only=0
while (($#)); do
	case $1 in
	--check) check_only=1; shift ;;
	--dry-run) dry_run=1; shift ;;
	*) die "$1 is not an option" ;;
	esac
done

name=agents-hosted
vm_account_name=agents-hosted-vm
key=hosted
subnet_range=10.62.0.0/24
snapshots=$name-daily
key_file=${AGENTS_GCP_KEY_FILE:-$HOME/.agents/secrets/gcp-agents-hosted.json}
project=${AGENTS_GCP_PROJECT:-}
zone=${AGENTS_GCP_ZONE:-}
machine_type=${AGENTS_HOSTED_MACHINE_TYPE:-e2-medium}
disk_gb=${AGENTS_HOSTED_DISK_GB:-50}

# Every missing input, said at once, before anything is made.
missing=()
for need in AGENTS_GCP_PROJECT AGENTS_GCP_ZONE AGENTS_HOSTED_DOMAIN AGENTS_HOSTED_ACCOUNTS_DOMAIN \
	AGENTS_HOSTED_GITHUB_SECRET ACME_EMAIL; do
	[[ -n ${!need:-} ]] || missing+=("$need")
done
[[ -s $key_file ]] || ((dry_run)) || missing+=("AGENTS_GCP_KEY_FILE (no key at $key_file)")
stripe=(AGENTS_HOSTED_STRIPE_KEY AGENTS_HOSTED_STRIPE_PRICE AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET)
stripe_set=0
for v in "${stripe[@]}"; do
	[[ -z ${!v:-} ]] || stripe_set=1
done
if ((stripe_set)); then
	for v in "${stripe[@]}"; do
		[[ -n ${!v:-} ]] || missing+=("$v (billing needs all three)")
	done
fi
[[ -z $zone || $zone =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] || missing+=("AGENTS_GCP_ZONE (\"$zone\" is not a zone, such as us-west1-b)")
[[ $disk_gb =~ ^[0-9]+$ ]] || missing+=("AGENTS_HOSTED_DISK_GB (a whole number of GB)")
if ((${#missing[@]})); then
	printf '%s: nothing was made. Set:\n' "${0##*/}" >&2
	printf '  %s\n' "${missing[@]}" >&2
	exit 1
fi
if ((check_only)); then
	say "Everything hosted-up.sh needs is set."
	exit 0
fi
region=${zone%-*}
domain=$AGENTS_HOSTED_DOMAIN
accounts_domain=$AGENTS_HOSTED_ACCOUNTS_DOMAIN

if ! ((dry_run)); then
	command -v gcloud >/dev/null || die "gcloud is needed: brew install --cask gcloud-cli"
fi
vm_account=$vm_account_name@$project.iam.gserviceaccount.com
export CLOUDSDK_CONFIG=$HOME/.agents/gcloud/agents-hosted
export CLOUDSDK_CORE_PROJECT=$project
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
((dry_run)) || mkdir -p "$CLOUDSDK_CONFIG"
say "CLOUDSDK_CONFIG=$CLOUDSDK_CONFIG CLOUDSDK_CORE_PROJECT=$project"
run gcloud auth activate-service-account --key-file "$key_file" --quiet
kms=projects/$project/locations/$key_location/keyRings/$keyring/cryptoKeys/$key

say "== Compute Engine, Cloud KMS and IAM"
run gcloud services enable compute.googleapis.com cloudkms.googleapis.com iam.googleapis.com
retry gcloud iam service-accounts list --limit 1 --format none

say "== the key that seals each account's control key: $kms"
exists gcloud kms keyrings describe "$keyring" --location "$key_location" ||
	run gcloud kms keyrings create "$keyring" --location "$key_location"
exists gcloud kms keys describe "$key" --keyring "$keyring" --location "$key_location" ||
	run gcloud kms keys create "$key" --keyring "$keyring" --location "$key_location" --purpose encryption

say "== the VM's service account, which may use only that key: $vm_account"
exists gcloud iam service-accounts describe "$vm_account" ||
	run gcloud iam service-accounts create "$vm_account_name" --display-name "Agents hosted service VM"
retry gcloud kms keys add-iam-policy-binding "$key" --keyring "$keyring" --location "$key_location" \
	--member "serviceAccount:$vm_account" --role roles/cloudkms.cryptoKeyEncrypterDecrypter --format none

say "== the network, and its firewall"
exists gcloud compute networks describe "$name" ||
	run gcloud compute networks create "$name" --subnet-mode custom
exists gcloud compute networks subnets describe "$name" --region "$region" ||
	run gcloud compute networks subnets create "$name" --network "$name" --region "$region" --range "$subnet_range"
exists gcloud compute firewall-rules describe "$name-web" ||
	run gcloud compute firewall-rules create "$name-web" --network "$name" --direction INGRESS \
		--allow tcp:80,tcp:443 --source-ranges 0.0.0.0/0 --target-tags "$name"
if ((dry_run)); then
	caller=198.51.100.7
	say "+ curl -4 -fsS https://checkip.amazonaws.com   (this machine's address; $caller stands in)"
else
	caller=$(curl -4 -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
	[[ $caller =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not tell this machine's IPv4 address"
fi
if exists gcloud compute firewall-rules describe "$name-ssh"; then
	run gcloud compute firewall-rules update "$name-ssh" --source-ranges "$caller/32"
else
	run gcloud compute firewall-rules create "$name-ssh" --network "$name" --direction INGRESS \
		--allow tcp:22 --source-ranges "$caller/32" --target-tags "$name"
fi

say "== the static IPv4 address"
exists gcloud compute addresses describe "$name" --region "$region" ||
	run gcloud compute addresses create "$name" --region "$region"
if ((dry_run)); then
	ip=203.0.113.10
	say "+ $(shown gcloud compute addresses describe "$name" --region "$region" --format 'value(address)')   ($ip stands in)"
else
	ip=$(gcloud compute addresses describe "$name" --region "$region" --format 'value(address)')
fi

say "== the VM"
if exists gcloud compute instances describe "$name" --zone "$zone"; then
	run gcloud compute instances add-metadata "$name" --zone "$zone" --metadata-from-file "startup-script=$here/startup.sh"
else
	run gcloud compute instances create "$name" --zone "$zone" --machine-type "$machine_type" \
		--image-family debian-12 --image-project debian-cloud \
		--boot-disk-size "${disk_gb}GB" --boot-disk-type pd-balanced \
		--network "$name" --subnet "$name" --address "$ip" --tags "$name" \
		--service-account "$vm_account" --scopes cloud-platform \
		--shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
		--metadata-from-file "startup-script=$here/startup.sh"
fi

say "== the disk's daily snapshots, kept $snapshot_days days: $snapshots"
exists gcloud compute resource-policies describe "$snapshots" --region "$region" ||
	run gcloud compute resource-policies create snapshot-schedule "$snapshots" --region "$region" \
		--daily-schedule --start-time "$snapshot_start" --max-retention-days "$snapshot_days" \
		--on-source-disk-delete keep-auto-snapshots --storage-location "$region"
if ((dry_run)); then
	disk=$name
	say "? $(shown gcloud compute instances describe "$name" --zone "$zone" --format 'value(disks[0].source.basename())')   ($disk stands in)"
	attached=''
else
	disk=$(gcloud compute instances describe "$name" --zone "$zone" --format 'value(disks[0].source.basename())')
	attached=$(gcloud compute disks describe "$disk" --zone "$zone" --format 'value(resourcePolicies)')
fi
[[ $attached == *"/$snapshots"* ]] ||
	run gcloud compute disks add-resource-policies "$disk" --zone "$zone" --resource-policies "$snapshots"

say
say "The VM's address is $ip."
say

# Both names must point at the VM before Caddy asks Let's Encrypt for certificates. The
# wildcard is checked by one name under it.
points() {
	if ((dry_run)); then
		say "? dig +short $1 @1.1.1.1   (is it $ip?)"
		return 0
	fi
	dig +short "$1" @1.1.1.1 | grep -qx "$ip"
}
if ! points "$domain" || ! points "check.$accounts_domain"; then
	say "$domain and *.$accounts_domain do not point at $ip yet. Make their A records, then run"
	say "deploy/gcp/hosted-up.sh again."
	exit 0
fi

say "== Docker on the VM (the startup script puts it on at the first boot)"
if ((dry_run)); then
	vm_ssh 'sudo docker compose version'
else
	for i in $(seq 1 30); do
		vm_ssh 'sudo docker compose version' >/dev/null 2>&1 && break
		((i == 30)) && die "Docker is not on the VM after 5 minutes: see gcloud compute ssh $name --zone $zone --command 'sudo journalctl -u google-startup-scripts'"
		sleep 10
	done
fi

say "== the image, built here"
version=${AGENTS_VERSION:-$("$root/scripts/version.sh")}
say "version $version"
run docker build --platform linux/amd64 --build-arg "VERSION=$version" \
	-f "$root/deploy/Containerfile" -t agents-control:latest "$root"

say "== what the VM runs, in /opt/agents"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/deploy/secrets"
cp "$root/deploy/compose.hosted.yaml" "$root/deploy/Caddyfile.hosted" "$stage/deploy/"
# No service account file: the VM's own service account uses the key.
: >"$stage/deploy/secrets/gcp-service-account"
# The settings, secrets too, go only into the VM's deploy/.env (mode 600), never to a log.
{
	printf '%s=%s\n' AGENTS_CONTROL_KMS "gcpkms://$kms" AGENTS_VERSION "$version"
	for v in AGENTS_HOSTED_DOMAIN AGENTS_HOSTED_ACCOUNTS_DOMAIN AGENTS_HOSTED_GITHUB_SECRET ACME_EMAIL \
		AGENTS_HOSTED_GITHUB_CLIENT_ID AGENTS_HOSTED_VIEWS_DOMAIN AGENTS_HOSTED_SIGNUP AGENTS_HOSTED_MAX_ACCOUNTS \
		AGENTS_HOSTED_MIN_GITHUB_AGE AGENTS_HOSTED_SIGNUPS_PER_ADDRESS AGENTS_HOSTED_SIGNUPS_PER_HOUR \
		AGENTS_HOSTED_MAX_COPIES AGENTS_HOSTED_CERTS_PER_HOUR AGENTS_HOSTED_CERTS_PER_WEEK "${stripe[@]}"; do
		[[ -z ${!v:-} ]] || printf '%s=%s\n' "$v" "${!v}"
	done
} >"$stage/deploy/.env.new"
chmod 600 "$stage/deploy/.env.new"
# The lines in .env.new replace the same names in the VM's deploy/.env; the others stay.
install='set -e; sudo mkdir -p /opt/agents; sudo tar -C /opt/agents --no-same-owner -xzf -; cd /opt/agents/deploy
sudo touch .env; sudo chmod 600 .env
while IFS= read -r line; do k=${line%%=*}; { sudo grep -v "^$k=" .env || true; echo "$line"; } | sudo tee .env.t >/dev/null; sudo mv .env.t .env; done < .env.new
sudo rm .env.new'
if ((dry_run)); then
	say "+ docker save agents-control:latest | gzip | $(shown gcloud compute ssh "$name" --zone "$zone" --quiet --command 'gunzip | sudo docker load')"
	say "+ tar -C STAGE -czf - deploy | $(shown gcloud compute ssh "$name" --zone "$zone" --quiet --command "$install")"
else
	docker save agents-control:latest | gzip | vm_ssh 'gunzip | sudo docker load'
	COPYFILE_DISABLE=1 tar --no-xattrs -C "$stage" -czf - deploy | vm_ssh "$install"
fi

compose='cd /opt/agents && sudo docker compose -f deploy/compose.hosted.yaml'
say "== agents-hosted and Caddy"
vm_ssh "$compose up -d --no-build"
if ((dry_run)); then
	say "? curl -fsS https://$domain/healthz   (until it says ok)"
else
	printf 'waiting for the certificate'
	for _ in $(seq 1 60); do
		curl -fsS "https://$domain/healthz" >/dev/null 2>&1 && break
		printf .
		sleep 2
	done
	say
	curl -fsS "https://$domain/healthz" >/dev/null ||
		die "https://$domain/healthz does not answer: see gcloud compute ssh $name --zone $zone --command '$compose logs caddy'"
fi
say
say "https://$domain is up, at $ip. The first invite link:"
say "    gcloud compute ssh $name --zone $zone --command '$compose exec -T hosted /agents-hosted admin invite'"
say "(with CLOUDSDK_CONFIG=$CLOUDSDK_CONFIG)"
