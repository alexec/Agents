#!/bin/sh
# Make this machine a host of an Agents control plane (058, US4).
#
#   curl -fsSL [--pinnedpubkey sha256//…] https://<control plane>/v1/install.sh | sh -s -- '<host code>' [name]
#   curl … | sh -s -- --join '<url>' '<pin or ->' '<person>' [name]
#
# With --join there is no code: the host asks to join as the person, shows a short code,
# and waits until the person approves it on a client (#994).
#
# Installs the host (agentsd, Go since #1136) for this user in ~/.agents-server, and starts
# it. It connects out to the control plane; nothing needs to reach this machine. Run it
# again with a new code to join again. The Swift host, and --impl, went in #1381.
set -eu

code= name= ask=
if [ "${1:-}" = --join ]; then
    [ $# -ge 4 ] || { echo "Say the control plane's address, its pin (or -) and the person." >&2; exit 2; }
    ask=1 url=$2 pin=$3 person=$4 name=${5:-}
    case "$url" in https://*) ;; *) echo "The control plane's address starts with https://." >&2; exit 2 ;; esac
else
    while [ $# -gt 0 ]; do
        if [ -z "$code" ]; then code=$1; elif [ -z "$name" ]; then name=$1; fi; shift
    done
    [ -n "$code" ] || { echo "Say the host code the control plane showed." >&2; exit 2; }
    case "$code" in agents-control:2:h:*) ;; *) echo "That is not a host code." >&2; exit 2 ;; esac
    # The code's own fields: agents-control:2:h:-:<key>:<secret>:<url>:<pin>:<name>
    url=$(printf %s "$code" | cut -d: -f7 | sed 's/%3[Aa]/:/g; s/%2[Ff]/\//g; s/%25/%/g')
    pin=$(printf %s "$code" | cut -d: -f8)
fi
name=${name:-$(hostname)}

fetch() {
    if [ "$pin" != "-" ]; then
        command -v curl >/dev/null 2>&1 || { echo "curl is needed to check the control plane's certificate." >&2; exit 1; }
        # The pin is base64url; curl wants base64 with its padding.
        b64=$(printf %s "$pin" | tr '_-' '/+')
        while [ $(( ${#b64} % 4 )) -ne 0 ]; do b64="$b64="; done
        curl -fsS --insecure --pinnedpubkey "sha256//$b64" -o "$2" "$url$1"
    else
        # A publicly trusted certificate: the system's own roots have to be there.
        if [ ! -e /etc/ssl/certs/ca-certificates.crt ] && [ ! -d /etc/ssl/certs ] && [ ! -e /etc/pki/tls/certs/ca-bundle.crt ]; then
            echo "This machine has no CA certificates to check the control plane with. Install ca-certificates first." >&2
            exit 1
        fi
        if command -v curl >/dev/null 2>&1; then curl -fsS -o "$2" "$url$1"; else wget -q -O "$2" "$url$1"; fi
    fi
}

case "$(uname -s)" in Linux) ;; *) echo "Hosts other than Macs run Linux." >&2; exit 1 ;; esac
case "$(uname -m)" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "$(uname -m) is not a machine the host is built for." >&2; exit 1 ;;
esac

d="$HOME/.agents-server"
umask 077
mkdir -p "$d/bin" "$d/root"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Fetching the host for $arch-linux from $url…"
fetch "/v1/servers/agentsd-linux-$arch.sha256" "$tmp/sha256" 2>/dev/null ||
    { echo "This control plane offers no host for $arch-linux." >&2; exit 1; }
fetch "/v1/servers/agentsd-linux-$arch" "$tmp/agentsd"
sha=$(tr -d ' \n' < "$tmp/sha256")
echo "$sha  $tmp/agentsd" | sha256sum -c - >/dev/null || { echo "The download did not match its checksum." >&2; exit 1; }
chmod 700 "$tmp/agentsd"
mv "$tmp/agentsd" "$d/bin/agentsd-$sha"
ln -sfn "agentsd-$sha" "$d/bin/current"

# The MCP servers Agents ships (#700), beside agentsd, which puts its own folder first on
# their PATH. One the control plane does not offer is left out, with a word.
for server in github-mcp linear-mcp gitlab-mcp email-mcp; do
    if fetch "/v1/servers/$server-linux-$arch.sha256" "$tmp/$server.sha256" 2>/dev/null &&
        fetch "/v1/servers/$server-linux-$arch" "$tmp/$server" 2>/dev/null &&
        echo "$(tr -d ' \n' < "$tmp/$server.sha256")  $tmp/$server" | sha256sum -c - >/dev/null 2>&1; then
        chmod 700 "$tmp/$server"
        mv "$tmp/$server" "$d/bin/$server"
    else
        echo "This control plane offers no $server for $arch-linux; the host runs without it." >&2
    fi
done

# The Node toolsets the control plane carries (#1312): the Go host installs Claude from
# them by itself, and Codex when asked, into ~/.agents-server/tools.
offered=
for runtime in claude codex; do
    mkdir -p "$tmp/toolsets/$runtime"
    ok=1
    for file in manifest.json package.json package-lock.json; do
        fetch "/v1/toolsets/$runtime/$file" "$tmp/toolsets/$runtime/$file" 2>/dev/null || { ok=0; break; }
    done
    if [ $ok = 1 ]; then
        mkdir -p "$d/toolsets"
        rm -rf "$d/toolsets/$runtime"
        mv "$tmp/toolsets/$runtime" "$d/toolsets/$runtime"
        offered="$offered $runtime"
    fi
done
[ -n "$offered" ] || echo "This control plane offers no toolsets; the host installs no Claude by itself." >&2

# A host already running here stops; it is started again below with the new code.
if [ -f "$d/root/daemon.lock" ]; then
    old=$(cat "$d/root/daemon.lock" 2>/dev/null || true)
    [ -n "$old" ] && kill "$old" 2>/dev/null || true
    sleep 1
fi
# The host enrols again with the new code. (The record of which host was installed,
# from when there were two, is gone with them.)
rm -f "$d/root/control-host.json" "$d/impl" "$d/root/control-join-shown"
if [ -n "$ask" ]; then
    # The person's id or name, the address and the pin, as JSON: none holds a quote.
    for v in "$url" "$pin" "$person"; do
        case "$v" in *'"'*|*'\'*) echo "The address, pin and person can't hold quotes." >&2; exit 2 ;; esac
    done
    printf '{"url":"%s","pin":"%s","person":"%s"}' "$url" "$pin" "$person" > "$d/root/control-join-ask"
    chmod 600 "$d/root/control-join-ask"
    rm -f "$d/root/control-join-code"
else
    printf %s "$code" > "$d/root/control-join-code"
    chmod 600 "$d/root/control-join-code"
    rm -f "$d/root/control-join-ask"
fi

unit="$HOME/.config/systemd/user/agents-host.service"
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<UNIT
[Unit]
Description=Agents host ($name)
After=network-online.target

[Service]
ExecStart=%h/.agents-server/bin/current --root %h/.agents-server/root --serve --control-network --host-name "$name"
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable agents-host.service >/dev/null
    systemctl --user restart agents-host.service
    echo "Started as the systemd user service agents-host."
    echo "To keep it running after you log out: loginctl enable-linger $(id -un)"
else
    "$d/bin/current" --root "$d/root" --serve --detach --control-network --host-name "$name"
    echo "Started in the background (no systemd user session here)."
fi

wait=30
if [ -n "$ask" ]; then
    # Up to the request's 10 minutes, and a little more.
    wait=660
    i=0
    while [ ! -f "$d/root/control-join-shown" ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
    if [ -f "$d/root/control-join-shown" ]; then
        echo "Waiting for approval. On a client of $person, approve $name. Check that it shows the code $(cat "$d/root/control-join-shown")."
    fi
fi
i=0
while [ ! -f "$d/root/control-host.json" ] && [ $i -lt $wait ]; do sleep 1; i=$((i + 1)); done
if [ -f "$d/root/control-host.json" ]; then
    echo "$name joined the control plane."
else
    echo "The host started but has not joined yet. Its log: $d/root/daemon.log" >&2
    exit 1
fi