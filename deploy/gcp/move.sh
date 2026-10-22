#!/usr/bin/env bash
# The VM's side of a move of the control plane from a Mac to the VM (#1567), as the steps in
# docs/how-to/run-the-control-plane-in-the-cloud.md ("Move the control plane from your Mac").
#
#   deploy/gcp/move.sh [--dry-run] [--build] receive control-key
#   deploy/gcp/move.sh [--dry-run] done
#
# receive: before Check in the Move sheet. It stops the control plane on the VM, saves its store
# to /opt/agents/saved/store-<time>.tgz on the VM (a copy from an earlier move is kept, not
# lost), empties it, sets AGENTS_CONTROL_RECEIVE=1, and runs deploy/gcp/up.sh --seal-key with the
# key that Save Key… wrote. up.sh pulls the release's image (or, with --build, builds this
# checkout), copies the rest, seals the key and starts the control plane. Then it deletes the key file here.
#
# done: after Move Now. It takes AGENTS_CONTROL_RECEIVE=1 out of the VM's deploy/.env, so a lost
# store does not wait for a move again.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=deploy/gcp/common.sh
. "$here/common.sh"

up_args=()
while (($#)); do
	case $1 in
	--dry-run) dry_run=1; up_args+=(--dry-run); shift ;;
	--build) build=1; up_args+=(--build); shift ;;
	*) break ;;
	esac
done
what=${1:-}
case $what in
receive)
	key_in=${2:?receive needs the key file that Save Key… wrote}
	[[ -s $key_in ]] || ((dry_run)) || die "$key_in is not a key file"
	;;
done) ;;
*) die "say receive control-key, or done" ;;
esac

# Before the store is emptied: up.sh must have an image to start.
[[ $what == "done" ]] || pick_version

setup
compose='cd /opt/agents && sudo docker compose -f deploy/compose.public.yaml'

if [[ $what == "done" ]]; then
	say "== AGENTS_CONTROL_RECEIVE out of /opt/agents/deploy/.env"
	vm_ssh 'cd /opt/agents/deploy && { sudo grep -v "^AGENTS_CONTROL_RECEIVE=" .env || true; } | sudo tee .env.t >/dev/null && sudo mv .env.t .env && sudo chmod 600 .env'
	say "Done. The control plane keeps running on the store it took."
	exit 0
fi

say "== the control plane on the VM, stopped, and its store saved and emptied"
vm_ssh "set -e; $compose down
if sudo docker volume inspect agents-control_data >/dev/null 2>&1; then
	sudo mkdir -p /opt/agents/saved; sudo chmod 700 /opt/agents/saved
	f=/opt/agents/saved/store-\$(date -u +%Y%m%dT%H%M%SZ).tgz
	sudo tar -C \"\$(sudo docker volume inspect -f '{{.Mountpoint}}' agents-control_data)\" -czf \"\$f\" .
	sudo chmod 600 \"\$f\"; echo \"saved: \$f\"
	sudo docker volume rm agents-control_data
fi
cd /opt/agents/deploy; { sudo grep -v '^AGENTS_CONTROL_RECEIVE=' .env || true; echo AGENTS_CONTROL_RECEIVE=1; } | sudo tee .env.t >/dev/null; sudo mv .env.t .env; sudo chmod 600 .env"

say "== up.sh, with the key sealed before the first start"
run "$here/up.sh" ${up_args[@]+"${up_args[@]}"} --seal-key "$key_in"
run rm -f "$key_in"
say
say "The key file $key_in is deleted. In the Move sheet, click Continue, type"
say "https://control.agentloops.dev and click Check. After Move Now: deploy/gcp/move.sh done"
