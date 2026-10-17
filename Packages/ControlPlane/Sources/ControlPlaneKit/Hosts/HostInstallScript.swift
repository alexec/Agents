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
    for server in github-mcp linear-mcp; do
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
    """#

    /// The one line a person runs on the server, for a host code.
    public static func command(url: String, pin: String?, code: String, implementation: String? = nil) -> String {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        var curl = "curl -fsSL"
        if let pin, !pin.isEmpty {
            var standard = pin.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while standard.count % 4 != 0 { standard += "=" }
            curl += " --insecure --pinnedpubkey sha256//\(standard)"
        }
        // The Go host is the script's own default (#1136): only the Swift one is asked for.
        let impl = implementation == "swift" ? " --impl swift" : ""
        return "\(curl) \(base)/v1/install.sh | sh -s -- '\(code)'\(impl)"
    }
}

/// The Linux host binaries a control plane hands out: Agents Host's own
/// (`Contents/Resources/servers`, beside `Contents/Helpers/agents-control`), a container's
/// `/servers`, or `AGENTS_CONTROL_SERVERS`.
public enum ServerFiles {
    /// The MCP servers Agents ships (#700), installed beside agentsd as `bin/<name>`:
    /// github-mcp (#1232) and linear-mcp (#839) are built by scripts/build-linux-agentsd-go.sh.
    public static let shippedServers = ["github-mcp", "linear-mcp"]

    public static let names: Set<String> = {
        var all: Set<String> = ["VERSION", "VERSION-go"]
        for arch in ["x86_64", "aarch64"] {
            // agentsd-go (#1136): the Go host, built by scripts/build-linux-agentsd-go.sh.
            for program in ["agentsd", "agentsd-go"] + shippedServers {
                all.insert("\(program)-linux-\(arch)")
                all.insert("\(program)-linux-\(arch).sha256")
            }
        }
        return all
    }()

    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if let given = environment["AGENTS_CONTROL_SERVERS"] { candidates.append(URL(fileURLWithPath: given, isDirectory: true)) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/servers", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/servers", isDirectory: true))
        // A folder with either host: a Go-only one (scripts/build-linux-agentsd-go.sh alone) too.
        return candidates.first { folder in
            ["VERSION", "VERSION-go"].contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        }
    }

    /// A file by name, from the folder: never a path the request made up.
    public static func read(_ name: String, in folder: URL?) -> Data? {
        guard names.contains(name), let folder else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(name))
    }

    /// The shipped MCP servers the folder has for `arch`, each with its checksum.
    public static func shippedServers(for arch: String, in folder: URL?) -> [(name: String, file: URL, sha256: String)] {
        guard let folder else { return [] }
        return shippedServers.compactMap { name in
            guard let sha = read("\(name)-linux-\(arch).sha256", in: folder).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
            return (name, folder.appendingPathComponent("\(name)-linux-\(arch)"), sha.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Each architecture the folder has, with its checksum and the version beside them:
    /// the Go host (#1136), or with `implementation` `swift` the Swift one. Asked for
    /// neither, a folder with no Go host for `arch` gives the Swift one.
    public static func binary(for arch: String, implementation: String? = nil,
                              in folder: URL?) -> (file: URL, sha256: String, version: String)? {
        if implementation == nil, read("agentsd-go-linux-\(arch).sha256", in: folder) == nil {
            return binary(for: arch, implementation: "swift", in: folder)
        }
        let go = implementation != "swift"
        let program = go ? "agentsd-go" : "agentsd"
        guard let folder,
              let sha = read("\(program)-linux-\(arch).sha256", in: folder).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let version = read(go ? "VERSION-go" : "VERSION", in: folder)
            .map { String(decoding: $0, as: UTF8.self) } ?? "0"
        return (folder.appendingPathComponent("\(program)-linux-\(arch)"), sha.trimmingCharacters(in: .whitespacesAndNewlines),
                version.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
