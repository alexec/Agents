#!/bin/sh
# Make this machine a host of an Agents control plane (058, US4).
#
#   curl -fsSL [--pinnedpubkey sha256//…] https://<control plane>/v1/install.sh | sh -s -- '<host code>' [name] [--impl swift]
#
# Installs the host for this user in ~/.agents-server, and starts it. It connects out to
# the control plane; nothing needs to reach this machine. Run it again with a new code to
# join again. It installs the Go host (#1136); --impl swift (or AGENTS_HOST_IMPL=swift)
# installs the Swift host instead. Both use the same root, so a host that changes keeps
# its agents.
set -eu

code= name= impl=${AGENTS_HOST_IMPL:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --impl) impl=${2:?say swift or go after --impl}; shift 2 ;;
        --impl=*) impl=${1#--impl=}; shift ;;
        *) if [ -z "$code" ]; then code=$1; elif [ -z "$name" ]; then name=$1; fi; shift ;;
    esac
done
[ -n "$code" ] || { echo "Say the host code the control plane showed." >&2; exit 2; }
asked=$impl impl=${impl:-go}
name=${name:-$(hostname)}
case "$code" in agents-control:2:h:*) ;; *) echo "That is not a host code." >&2; exit 2 ;; esac
case "$impl" in swift) program=agentsd ;; go) program=agentsd-go ;; *) echo "--impl is swift or go." >&2; exit 2 ;; esac

# The code's own fields: agents-control:2:h:-:<key>:<secret>:<url>:<pin>:<name>
url=$(printf %s "$code" | cut -d: -f7 | sed 's/%3[Aa]/:/g; s/%2[Ff]/\//g; s/%25/%/g')
pin=$(printf %s "$code" | cut -d: -f8)

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

echo "Fetching the host ($impl) for $arch-linux from $url…"
if ! fetch "/v1/servers/$program-linux-$arch.sha256" "$tmp/sha256" 2>/dev/null; then
    # A control plane from before the Go host was the default offers only the Swift one.
    [ -z "$asked" ] && [ "$impl" = go ] || { echo "This control plane offers no $impl host for $arch-linux." >&2; exit 1; }
    echo "This control plane offers no Go host for $arch-linux; installing the Swift host." >&2
    impl=swift program=agentsd
    fetch "/v1/servers/$program-linux-$arch.sha256" "$tmp/sha256"
fi
fetch "/v1/servers/$program-linux-$arch" "$tmp/agentsd"
sha=$(tr -d ' \n' < "$tmp/sha256")
echo "$sha  $tmp/agentsd" | sha256sum -c - >/dev/null || { echo "The download did not match its checksum." >&2; exit 1; }
chmod 700 "$tmp/agentsd"
mv "$tmp/agentsd" "$d/bin/agentsd-$sha"
ln -sfn "agentsd-$sha" "$d/bin/current"

# The MCP servers Agents ships (#700), beside agentsd, which puts its own folder first on
# their PATH. One the control plane does not offer is left out, with a word.
for server in ci-watcher github-mcp linear-mcp; do
    if fetch "/v1/servers/$server-linux-$arch.sha256" "$tmp/$server.sha256" 2>/dev/null &&
        fetch "/v1/servers/$server-linux-$arch" "$tmp/$server" 2>/dev/null &&
        echo "$(tr -d ' \n' < "$tmp/$server.sha256")  $tmp/$server" | sha256sum -c - >/dev/null 2>&1; then
        chmod 700 "$tmp/$server"
        mv "$tmp/$server" "$d/bin/$server"
    else
        echo "This control plane offers no $server for $arch-linux; the host runs without it." >&2
    fi
done

# A host already running here stops; it is started again below with the new code.
if [ -f "$d/root/daemon.lock" ]; then
    old=$(cat "$d/root/daemon.lock" 2>/dev/null || true)
    [ -n "$old" ] && kill "$old" 2>/dev/null || true
    sleep 1
fi
# Changing between the Swift and the Go host (#1136) on a root already joined to this
# control plane keeps its membership, so the host keeps its id; the code goes unused.
# Otherwise, as always, the host enrols again with the new code.
previous=$(cat "$d/impl" 2>/dev/null || echo swift)
keep=0
if [ "$previous" != "$impl" ] && [ -f "$d/root/control-host.json" ]; then
    key=$(printf %s "$code" | cut -d: -f5 | tr '_-' '/+')
    while [ $(( ${#key} % 4 )) -ne 0 ]; do key="$key="; done
    kept=$(sed 's#\\/#/#g' "$d/root/control-host.json" | sed -n 's/.*"controlKey" *: *"\([^"]*\)".*/\1/p')
    [ -n "$kept" ] && [ "$kept" = "$key" ] && keep=1
fi
printf %s "$impl" > "$d/impl"
if [ $keep = 1 ]; then
    echo "Changing from the $previous host to the $impl host: it keeps its place in the control plane."
else
    rm -f "$d/root/control-host.json"
    printf %s "$code" > "$d/root/control-join-code"
    chmod 600 "$d/root/control-join-code"
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

i=0
while [ ! -f "$d/root/control-host.json" ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
if [ -f "$d/root/control-host.json" ]; then
    echo "$name joined the control plane."
else
    echo "The host started but has not joined yet. Its log: $d/root/daemon.log" >&2
    exit 1
fi