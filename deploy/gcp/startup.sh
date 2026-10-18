#!/usr/bin/env bash
# The VM's startup script (#1461), run by Google Cloud as root at each boot. deploy/gcp/up.sh
# puts it in the VM's metadata.
#
# - Docker and its Compose plugin, from Docker's own Debian repository, once;
# - 2 GB of swap, once: an e2-micro has 1 GB of memory;
# - the control plane and Caddy, when up.sh has copied them to /opt/agents. Their restart
#   policy starts them again after a reboot too; this is for a boot after Docker was put on.
set -euo pipefail

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q
	apt-get install -yq ca-certificates curl
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc
	# shellcheck source=/dev/null
	codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $codename stable" \
		>/etc/apt/sources.list.d/docker.list
	apt-get update -q
	apt-get install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin
	systemctl enable --now docker
fi

if [[ ! -f /swapfile ]]; then
	fallocate -l 2G /swapfile
	chmod 600 /swapfile
	mkswap /swapfile
	echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi
swapon --show | grep -q /swapfile || swapon /swapfile

if [[ -f /opt/agents/deploy/compose.public.yaml && -f /opt/agents/deploy/.env ]]; then
	cd /opt/agents
	docker compose -f deploy/compose.public.yaml up -d --no-build
fi
