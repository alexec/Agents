import AgentsKitCore
import Foundation

/// What a server runs to become a host (058, US4, T070): served at `GET /v1/install.sh`, and
/// the command `hosts/startEnroll` shows pipes it to `sh` with a one-time host code.
///
/// It fetches the Linux host from the control plane itself (`/v1/servers/…`), checks its
/// SHA-256, installs it for the user in `~/.agents-server`, leaves the code in the host's root
/// and starts it: under a systemd user unit where there is one, detached otherwise. The host
/// then enrols over its own connection out; nothing has to reach the server.
///
/// `scripts/host-install.sh` is this text, written by `agents-control install-script`.
public enum HostInstallScript {
    public static let text = #"""
    #!/bin/sh
    # Make this machine a host of an Agents control plane (058, US4).
    #
    #   curl -fsSL [--pinnedpubkey sha256//…] https://<control plane>/v1/install.sh | sh -s -- '<host code>' [name]
    #
    # Installs the host for this user in ~/.agents-server, and starts it. It connects out to
    # the control plane; nothing needs to reach this machine. Run it again with a new code to
    # join again.
    set -eu

    code=${1:?say the host code the control plane showed}
    name=${2:-$(hostname)}
    case "$code" in agents-control:2:h:*) ;; *) echo "That is not a host code." >&2; exit 2 ;; esac

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

    echo "Fetching the host for $arch-linux from $url…"
    fetch "/v1/servers/agentsd-linux-$arch.sha256" "$tmp/sha256"
    fetch "/v1/servers/agentsd-linux-$arch" "$tmp/agentsd"
    sha=$(tr -d ' \n' < "$tmp/sha256")
    echo "$sha  $tmp/agentsd" | sha256sum -c - >/dev/null || { echo "The download did not match its checksum." >&2; exit 1; }
    chmod 700 "$tmp/agentsd"
    mv "$tmp/agentsd" "$d/bin/agentsd-$sha"
    ln -sfn "agentsd-$sha" "$d/bin/current"

    # A host already running here stops; it is started again below with the new code.
    if [ -f "$d/root/daemon.lock" ]; then
        old=$(cat "$d/root/daemon.lock" 2>/dev/null || true)
        [ -n "$old" ] && kill "$old" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$d/root/control-host.json"
    printf %s "$code" > "$d/root/control-join-code"
    chmod 600 "$d/root/control-join-code"

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
    """#

    /// The one line a person runs on the server, for a host code.
    public static func command(url: String, pin: String?, code: String) -> String {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        var curl = "curl -fsSL"
        if let pin, !pin.isEmpty {
            var standard = pin.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while standard.count % 4 != 0 { standard += "=" }
            curl += " --insecure --pinnedpubkey sha256//\(standard)"
        }
        return "\(curl) \(base)/v1/install.sh | sh -s -- '\(code)'"
    }
}

/// The Linux host binaries a control plane hands out: Agents Host's own
/// (`Contents/Resources/servers`, beside `Contents/Helpers/agents-control`), a container's
/// `/servers`, or `AGENTS_CONTROL_SERVERS`.
public enum ServerFiles {
    public static let names: Set<String> = {
        var all: Set<String> = ["VERSION"]
        for arch in ["x86_64", "aarch64"] { all.insert("agentsd-linux-\(arch)"); all.insert("agentsd-linux-\(arch).sha256") }
        return all
    }()

    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if let given = environment["AGENTS_CONTROL_SERVERS"] { candidates.append(URL(fileURLWithPath: given, isDirectory: true)) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/servers", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/servers", isDirectory: true))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("VERSION").path) }
    }

    /// A file by name, from the folder: never a path the request made up.
    public static func read(_ name: String, in folder: URL?) -> Data? {
        guard names.contains(name), let folder else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(name))
    }

    /// Each architecture the folder has, with its checksum and the version beside them.
    public static func binary(for arch: String, in folder: URL?) -> (file: URL, sha256: String, version: String)? {
        guard let folder,
              let sha = read("agentsd-linux-\(arch).sha256", in: folder).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let version = read("VERSION", in: folder).map { String(decoding: $0, as: UTF8.self) } ?? "0"
        return (folder.appendingPathComponent("agentsd-linux-\(arch)"), sha.trimmingCharacters(in: .whitespacesAndNewlines),
                version.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
