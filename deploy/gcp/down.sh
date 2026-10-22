#!/usr/bin/env bash
# Remove what deploy/gcp/up.sh made (#1461): the VM and its disk, the static address, the
# firewall, the network and the VM's service account. It asks first.
#
#   deploy/gcp/down.sh [--dry-run] [--destroy-key]
#
# The store is on the VM's disk (the Docker volume agents-control_data): every host, client
# and the sealed control key. Deleting the disk deletes them, and every window, phone and host
# must pair again. Move the control plane away first if it is in use.
#
# The Cloud KMS key stays, unless --destroy-key: it costs about $0.06 a month, and a copy of the
# store elsewhere opens only with it. With --destroy-key, each of its versions is destroyed
# (Google Cloud waits 30 days first, and until then `gcloud kms keys versions restore` brings it
# back). A key ring can never be deleted; an empty one costs nothing.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=deploy/gcp/common.sh
. "$here/common.sh"

destroy_key=0
while (($#)); do
	case $1 in
	--dry-run) dry_run=1; shift ;;
	--destroy-key) destroy_key=1; shift ;;
	*) die "$1 is not an option" ;;
	esac
done

setup
say
say "This deletes the VM $name in $project and its disk. The control plane's store is on that"
say "disk: every host and client, and the sealed control key. Every window, phone and host"
say "must then pair again."
((destroy_key)) && say "It also destroys the Cloud KMS key $key: a copy of the store elsewhere can then not be opened."
if ((dry_run)); then
	say "(--dry-run: nothing is asked, and nothing is deleted)"
else
	read -r -p "Type the project id ($project) to delete them: " answer
	[[ $answer == "$project" ]] || die "nothing deleted"
fi

if exists gcloud compute instances describe "$name" --zone "$zone"; then
	run gcloud compute instances delete "$name" --zone "$zone" --delete-disks all --quiet
fi
# The schedule goes with the disk; the snapshots it made stay (#2136), as the one copy of the
# store left. Each is billed by the GB a month until it is deleted.
if exists gcloud compute resource-policies describe "$snapshots" --region "$region"; then
	run gcloud compute resource-policies delete "$snapshots" --region "$region" --quiet
fi
if exists gcloud compute addresses describe "$name" --region "$region"; then
	run gcloud compute addresses delete "$name" --region "$region" --quiet
fi
for rule in "$name-web" "$name-ssh"; do
	if exists gcloud compute firewall-rules describe "$rule"; then
		run gcloud compute firewall-rules delete "$rule" --quiet
	fi
done
if exists gcloud compute networks subnets describe "$name" --region "$region"; then
	run gcloud compute networks subnets delete "$name" --region "$region" --quiet
fi
if exists gcloud compute networks describe "$name"; then
	run gcloud compute networks delete "$name" --quiet
fi
if exists gcloud iam service-accounts describe "$vm_account"; then
	# The key's policy names the account; take it out, so no "deleted:" member is left.
	run gcloud kms keys remove-iam-policy-binding "$key" --keyring "$keyring" --location "$key_location" \
		--member "serviceAccount:$vm_account" --role roles/cloudkms.cryptoKeyEncrypterDecrypter --format none || true
	run gcloud iam service-accounts delete "$vm_account" --quiet
fi

if ((destroy_key)); then
	if ((dry_run)); then
		versions=1
		say "? $(shown gcloud kms keys versions list --key "$key" --keyring "$keyring" --location "$key_location" \
			--filter 'state=ENABLED OR state=DISABLED' --format 'value(name.basename())')   (1 stands in)"
	else
		versions=$(gcloud kms keys versions list --key "$key" --keyring "$keyring" --location "$key_location" \
			--filter 'state=ENABLED OR state=DISABLED' --format 'value(name.basename())' 2>/dev/null || true)
	fi
	for v in $versions; do
		run gcloud kms keys versions destroy "$v" --key "$key" --keyring "$keyring" --location "$key_location" --quiet
	done
fi
say "Removed. The DNS records for the names still point at the old address: remove them at Cloudflare."
say "The disk's snapshots are kept, and billed until deleted. To delete them:"
say "  $(shown gcloud compute snapshots list --filter "sourceDisk~/$name" --format 'value(name)') | xargs gcloud compute snapshots delete --quiet"
