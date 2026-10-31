#!/usr/bin/env bash
# The control plane on a Google Cloud VM (#1461), from nothing to https://control.agentloops.dev,
# acting as the service account in ~/.agents/secrets/gcp-agents-control.json (its project is the
# file's). Each step first looks for what it makes, so running it again is safe, and carries on
# where it stopped.
#
#   deploy/gcp/up.sh [--dry-run] [--build] [--cloudflare] [--apns AuthKey_KEYID.p8 [--apns-key-id KEYID]]
#       [--email you@example.com] [--domain control.agentloops.dev] [--views-domain views.agentloops.dev]
#       [--seal-key control-key]
#
# What it makes:
# - Compute Engine, Cloud KMS and IAM turned on in the project;
# - the Cloud KMS key ring "agents" and key "control" (global), which seals the control key (#1458);
# - the service account agents-control-vm, which may only encrypt and decrypt with that key;
# - the network agents-control (us-west1), with 80 and 443 open to all (or, with --cloudflare,
#   only to Cloudflare's own ranges: #2151), and 22 open only to this machine's IPv4 address
#   (made again at each run, for a new address);
# - the static IPv4 address agents-control, about $3.65 a month;
# - the e2-micro VM agents-control in us-west1-b, Debian with a 30 GB standard disk (the free
#   tier's), running as agents-control-vm, with deploy/gcp/startup.sh to put Docker on it;
# - the snapshot schedule agents-control-daily on that disk: a snapshot each day at 10:00 UTC,
#   each kept 7 days, in us-west1 (#2136). The store, the sealed key and the certificate are
#   all on the disk, so a snapshot restores the whole control plane.
#
# Then it prints the address, and stops until both names point at it (deploy/cloudflare/dns.sh):
# Let's Encrypt allows only a few failed tries an hour. Run it again after that, and it copies
# deploy/compose.public.yaml and the secrets to /opt/agents on the VM, has the VM pull the
# release's image, ghcr.io/alexec/agents-control:<version> (#2140), which carries the Linux host
# for servers that join, and starts the control plane and Caddy there. --build is for a commit
# no release has: it builds the image (linux/amd64) here, from this checkout, and copies it. The VM has no service
# account file (an empty one): it uses the key as its own service account.
#
# --apns gives the APNs key (deploy/make-secrets.sh --apns); without it, a key already on the
# VM is kept. The VAPID key for Web Push (#1486) is made on the VM the first time and never
# sent: a new one would end every browser's subscription. --seal-key seals a control key from elsewhere before the first start, for a move
# from a Mac (docs/how-to/run-the-control-plane-in-the-cloud.md). --dry-run prints every command
# and runs none: it needs no gcloud, no key file and no account.
#
# --cloudflare locks the firewall to Cloudflare's own ranges (#2151), so only its proxy
# reaches the VM; once locked, a later run with no flag leaves it locked (it's only ever
# widened by a fresh VM's own first run). Run deploy/cloudflare/dns.sh --proxied first, and
# wait for it to take: this shuts out anyone still going straight to the VM's address. Caddy
# already trusts only those ranges for the real client address (deploy/Caddyfile.public),
# whether or not this flag is given, so giving it late costs nothing but a moment with the
# firewall wider than it need be.
#
# AGENTS_VERSION is the version it runs: a release sets it to the tag's, X.Y.Z (#2100), whose
# image it pulls. Without it, scripts/version.sh says. That is a release's only
# on its tag, so elsewhere give --build, which stamps that version on what it builds. At the end
# it checks that the control plane running on the VM says that version.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
# shellcheck source=deploy/gcp/common.sh
. "$here/common.sh"

domain=control.agentloops.dev
views_domain=views.agentloops.dev
email=''
apns=()
seal_key=''
cloudflare=0
while (($#)); do
	case $1 in
	--dry-run) dry_run=1; shift ;;
	--build) build=1; shift ;;
	--cloudflare) cloudflare=1; shift ;;
	--apns) apns+=(--apns "${2:?--apns needs the .p8 file}"); shift 2 ;;
	--apns-key-id) apns+=(--apns-key-id "${2:?--apns-key-id needs the Key ID}"); shift 2 ;;
	--email) email=${2:?--email needs an address}; shift 2 ;;
	--domain) domain=${2:?--domain needs a name}; shift 2 ;;
	--views-domain) views_domain=${2:?--views-domain needs a name}; shift 2 ;;
	--seal-key) seal_key=${2:?--seal-key needs the key file}; shift 2 ;;
	*) die "$1 is not an option" ;;
	esac
done
[[ -n $email ]] || email=$(git -C "$root" config user.email || true)
[[ -n $email ]] || die "say the address Let's Encrypt writes to: --email you@example.com"
[[ -z $seal_key || -s $seal_key ]] || die "$seal_key is not a key file"
# Look before anything is made in the cloud.
pick_version
# With --build, the image is built for linux/amd64. On an Apple silicon Mac the classic builder
# cannot do it: it needs BuildKit, through the buildx plugin.
((!build || dry_run)) || docker buildx version >/dev/null 2>&1 ||
	die "docker buildx is not installed: brew install docker-buildx, then link it for Docker: mkdir -p ~/.docker/cli-plugins && ln -sfn \$(brew --prefix)/opt/docker-buildx/bin/docker-buildx ~/.docker/cli-plugins/docker-buildx"

setup
kms=projects/$project/locations/$key_location/keyRings/$keyring/cryptoKeys/$key

say "== Compute Engine, Cloud KMS and IAM"
run gcloud services enable compute.googleapis.com cloudkms.googleapis.com iam.googleapis.com
# The IAM API needs about a minute after it is first turned on. Until then the describe below
# fails as if there were no account, and the create fails too (#1461).
retry gcloud iam service-accounts list --limit 1 --format none

say "== the key that seals the control key: $kms"
exists gcloud kms keyrings describe "$keyring" --location "$key_location" ||
	run gcloud kms keyrings create "$keyring" --location "$key_location"
exists gcloud kms keys describe "$key" --keyring "$keyring" --location "$key_location" ||
	run gcloud kms keys create "$key" --keyring "$keyring" --location "$key_location" --purpose encryption

say "== the VM's service account, which may use only that key: $vm_account"
exists gcloud iam service-accounts describe "$vm_account" ||
	run gcloud iam service-accounts create "$vm_account_name" --display-name "Agents control plane VM"
retry gcloud kms keys add-iam-policy-binding "$key" --keyring "$keyring" --location "$key_location" \
	--member "serviceAccount:$vm_account" --role roles/cloudkms.cryptoKeyEncrypterDecrypter --format none

say "== the network, and its firewall"
exists gcloud compute networks describe "$name" ||
	run gcloud compute networks create "$name" --subnet-mode custom
exists gcloud compute networks subnets describe "$name" --region "$region" ||
	run gcloud compute networks subnets create "$name" --network "$name" --region "$region" --range "$subnet_range"
# --cloudflare: only Cloudflare's own ranges reach 80 and 443, so nobody can go around its
# proxy and rate rules (#2151) to the VM directly. Fetched fresh each run, so a change to
# Cloudflare's list (rare) is picked up without editing this script. Flip the DNS records to
# proxied (deploy/cloudflare/dns.sh --proxied) first: run this before that, and real traffic,
# still going straight to the VM, is shut out until the DNS change reaches everyone.
#
# Without --cloudflare, an existing rule is left alone: a release that runs up.sh with no
# flag, after Alex has locked it down once, must not widen it back open. Only a rule made
# fresh here defaults to 0.0.0.0/0, as before #2151.
if exists gcloud compute firewall-rules describe "$name-web"; then web_exists=1; else web_exists=0; fi
if ((cloudflare)); then
	ips_args=(-4)
	((!dry_run)) || ips_args+=(--dry-run)
	web_ranges=$("$here/../cloudflare/ips.sh" "${ips_args[@]}" | paste -sd, -)
	[[ -n $web_ranges ]] || die "could not fetch Cloudflare's IPv4 ranges: see deploy/cloudflare/ips.sh"
fi
if ((web_exists)); then
	((cloudflare)) && run gcloud compute firewall-rules update "$name-web" --source-ranges "$web_ranges"
else
	run gcloud compute firewall-rules create "$name-web" --network "$name" --direction INGRESS \
		--allow tcp:80,tcp:443 --source-ranges "${web_ranges:-0.0.0.0/0}" --target-tags "$name"
fi
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
	run gcloud compute instances create "$name" --zone "$zone" --machine-type e2-micro \
		--image-family debian-12 --image-project debian-cloud \
		--boot-disk-size 30GB --boot-disk-type pd-standard \
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
# On the VM's boot disk, whatever its name: one restored from a snapshot is a new disk. Attached
# once: a disk refuses a policy it has already.
if ((dry_run)); then
	disk=$name
	say "? $(shown gcloud compute instances describe "$name" --zone "$zone" --format 'value(disks[0].source.basename())')   ($disk stands in)"
	say "? $(shown gcloud compute disks describe "$disk" --zone "$zone" --format 'value(resourcePolicies)')   (is $snapshots there?)"
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

# Both names must point at the VM before Caddy asks Let's Encrypt for their certificates.
points() {
	if ((dry_run)); then
		say "? dig +short $1 @1.1.1.1   (is it $ip?)"
		return 0
	fi
	dig +short "$1" @1.1.1.1 | grep -qx "$ip"
}
if ! points "$domain" || ! points "$views_domain"; then
	say "$domain and $views_domain do not point at $ip yet. Make their A records:"
	say "    deploy/cloudflare/dns.sh $ip"
	say "then run deploy/gcp/up.sh again."
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

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/deploy"
if ((build)); then
	say "== the image, with the Linux host in it, built here: $version"
	run docker build --platform linux/amd64 --build-arg "VERSION=$version" \
		-f "$root/deploy/Containerfile" -t "$image:$tag" "$root"
fi

say "== what the VM runs, in /opt/agents"
cp "$root/deploy/compose.public.yaml" "$root/deploy/Caddyfile.public" "$root/deploy/make-secrets.sh" "$stage/deploy/"
# The hand-back page's files (#1343), so a new copy of them goes with each run. Only
# deploy/gcp/site.sh turns the site on.
cp -R "$root/deploy/site" "$stage/deploy/site"
# No --service-account: an empty file, and the VM's own service account uses the key.
run "$stage/deploy/make-secrets.sh" --public --kms "$kms" ${apns[@]+"${apns[@]}"}
# Without --apns, a key already on the VM stays: the empty one is not sent. The VM's own VAPID
# key always stays.
tar_skip=(--exclude deploy/secrets/vapid-key)
((${#apns[@]})) || tar_skip+=(--exclude deploy/secrets/apns-key)
{
	printf '%s=%s\n' AGENTS_DOMAIN "$domain" AGENTS_VIEWS_DOMAIN "$views_domain" ACME_EMAIL "$email" \
		AGENTS_VERSION "$tag"
	if [[ -f $stage/deploy/.env ]]; then cat "$stage/deploy/.env"; fi
} >"$stage/deploy/.env.new"
rm -f "$stage/deploy/.env" "$stage/deploy/make-secrets.sh"
# The lines in .env.new replace the same names in the VM's deploy/.env; the others stay.
install='set -e; sudo mkdir -p /opt/agents; sudo tar -C /opt/agents --no-same-owner -xzf -; cd /opt/agents/deploy
sudo touch .env; sudo chmod 600 .env
while IFS= read -r line; do k=${line%%=*}; { sudo grep -v "^$k=" .env || true; echo "$line"; } | sudo tee .env.t >/dev/null; sudo mv .env.t .env; done < .env.new
sudo rm .env.new; [ -f secrets/apns-key ] || { sudo touch secrets/apns-key; sudo chmod 644 secrets/apns-key; }
[ -s secrets/vapid-key ] || { openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt |
sudo tee secrets/vapid-key >/dev/null; sudo chmod 644 secrets/vapid-key; }'
if ((dry_run)); then
	if ((build)); then
		say "+ docker save $image:$tag | gzip | $(shown gcloud compute ssh "$name" --zone "$zone" --quiet --command 'gunzip | sudo docker load')"
	fi
	say "+ tar -C STAGE ${tar_skip[*]-} -czf - deploy | $(shown gcloud compute ssh "$name" --zone "$zone" --quiet --command "$install")"
else
	if ((build)); then docker save "$image:$tag" | gzip | vm_ssh 'gunzip | sudo docker load'; fi
	COPYFILE_DISABLE=1 tar --no-xattrs -C "$stage" ${tar_skip[@]+"${tar_skip[@]}"} -czf - deploy | vm_ssh "$install"
fi

compose='cd /opt/agents && sudo docker compose -f deploy/compose.public.yaml'
if [[ -n $seal_key ]]; then
	say "== the control key from $seal_key, sealed in the store before the first start"
	if ((dry_run)); then
		say "+ $(shown gcloud compute ssh "$name" --zone "$zone" --quiet --command "$compose run --rm -T control key seal --key-fd 0") < $seal_key"
	else
		vm_ssh "$compose run --rm -T control key seal --key-fd 0" <"$seal_key"
	fi
fi

if ((!build)); then
	say "== the image, pulled on the VM: $image:$tag"
	vm_ssh "$compose pull --quiet control" ||
		die "the VM could not pull $image:$tag: is the package public (github.com/alexec/Agents/pkgs/container/agents-control)? Or give --build"
fi

say "== the control plane and Caddy"
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
# Each release pulls a new image, and the old ones stay on the one 30 GB disk with the store
# (#2290). Once the new one serves, every image no container uses goes.
say "== the images no container uses, removed"
vm_ssh 'sudo docker image prune -af'
# The version Settings ▸ Control plane shows is the running binary's own.
if ((dry_run)); then
	vm_ssh "$compose exec -T control /agents-control version"
else
	served=$(vm_ssh "$compose exec -T control /agents-control version" | tr -d '\r')
	say "$served"
	[[ $served == "agents-control $version "* ]] ||
		die "the control plane says \"$served\", not $version: see gcloud compute ssh $name --zone $zone --command '$compose logs control'"
fi
say
say "https://$domain is up, at $ip. The first window's code:"
say "    gcloud compute ssh $name --zone $zone --command '$compose exec -T control /agents-control code --client'"
say "(with CLOUDSDK_CONFIG=$CLOUDSDK_CONFIG)"
