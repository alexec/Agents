import AgentsKitCore
import Foundation

/// What the window puts on a server, and takes off again (037, contracts/ssh.md §§ 5–8).
///
/// Everything lives in `~/.agents-server/`, private to the person's account:
///
///     bin/agentsd-<sha>   one per version ever installed, until the next good connect
///     bin/current         which of them runs
///     install.json        the version and checksum `current` points at
///     root/               an ordinary daemon root
///
/// Every step goes over the master and is written so that failing part way leaves what
/// was there before: a binary arrives as a `.part` and is only renamed once its
/// checksum matches, and `current` moves last.
public struct ServerInstaller: Sendable {
    public let ssh: SSHCommand

    /// Under this much free space the install is refused before anything is written.
    public static let minimumFreeBytes: Int64 = 200 * 1024 * 1024

    public init(ssh: SSHCommand) { self.ssh = ssh }

    /// `agentsd-` and the first sixteen characters of its SHA-256. The checksum is the
    /// binary's identity: the app's own version number does not change between
    /// development builds, and two different binaries must never share a name.
    public static func binaryName(sha256: String) -> String {
        "agentsd-\(sha256.prefix(16))"
    }

    // MARK: § 5 Probe

    static let probeScript = """
        uname -sm; printf '%s\\n' "$HOME"; df -Pk "$HOME" | tail -1; \
        tr -d '\\n' < "$HOME/.agents-server/install.json" 2>/dev/null; echo; \
        grep -i '^[[:space:]]*AllowStreamLocalForwarding' /etc/ssh/sshd_config 2>/dev/null || echo default
        """

    public func probe() async throws -> ServerFacts {
        let out = try await run(Self.probeScript)
        return try Self.parseProbe(out.stdout)
    }

    static func parseProbe(_ text: String) throws -> ServerFacts {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 5 else { throw HostProblem.installFailed(text) }
        let uname = lines[0].split(separator: " ").map(String.init)
        guard uname.count == 2, lines[1].hasPrefix("/") else { throw HostProblem.installFailed(text) }
        // POSIX `df -P`: filesystem, 1024-blocks, used, available, capacity, mounted on.
        let df = lines[2].split(separator: " ", omittingEmptySubsequences: true)
        let freeKilobytes = df.count >= 4 ? Int64(df[3]) ?? 0 : 0
        var version: String?, sha: String?
        if let data = lines[3].data(using: .utf8), !lines[3].isEmpty,
           let install = try? JSONDecoder().decode(InstallRecord.self, from: data) {
            version = install.version
            sha = install.sha256
        }
        let forwarding = lines[4].lowercased()
        let forwardingOff = forwarding.contains("allowstreamlocalforwarding")
            && (forwarding.hasSuffix(" no") || forwarding.hasSuffix(" local"))
        return ServerFacts(system: uname[0], architecture: Architecture(uname: uname[1]), home: lines[1],
                           freeBytes: freeKilobytes * 1024, installedVersion: version, installedSHA256: sha,
                           streamLocalForwarding: !forwardingOff)
    }

    struct InstallRecord: Codable {
        var version: String
        var sha256: String
        var installedAt: String
        var installedBy: String
    }

    public static func checkRoom(_ facts: ServerFacts) throws {
        guard facts.freeBytes >= minimumFreeBytes else { throw HostProblem.diskFull(freeBytes: facts.freeBytes) }
    }

    // MARK: § 6 Install and swap

    /// Stream `binary` to `bin/agentsd-<sha>`. A mismatched checksum is an install that
    /// failed; on a first install nothing is left, on an update the old one is untouched.
    public func install(binary: URL, sha256: String, firstInstall: Bool) async throws {
        let name = Self.binaryName(sha256: sha256)
        let script = """
            set -e; umask 077; d="$HOME/.agents-server"; mkdir -p "$d/bin" "$d/root"; \
            chmod 700 "$d" "$d/bin" "$d/root"; \
            f="$d/bin/.\(name).part"; cat > "$f"; \
            echo "\(sha256)  $f" | sha256sum -c - >/dev/null; \
            chmod 700 "$f"; mv "$f" "$d/bin/\(name)"
            """
        let out = try await ssh.run(ssh.runArguments(script), stdin: binary)
        guard out.status == 0 else {
            if firstInstall {
                _ = try? await run(#"rm -rf "$HOME/.agents-server""#)
            } else {
                _ = try? await run(#"rm -f "$HOME"/.agents-server/bin/.agentsd-*.part"#)
            }
            if out.stderr.contains("FAILED") || out.stderr.contains("checksum") {
                throw HostProblem.installFailed("The copy on the server did not match. Nothing was changed.")
            }
            throw SSHCommand.classify(status: out.status, stderr: out.stderr, agentHasKeys: true)
                ?? .installFailed(out.stderr)
        }
    }

    /// Point `current` at an installed binary and record which it is. Last, so a
    /// failure anywhere before leaves the old one running.
    public func swapCurrent(to sha256: String, version: String, installedBy: String) async throws {
        let record = InstallRecord(version: version, sha256: sha256,
                                   installedAt: ISO8601DateFormatter().string(from: Date()),
                                   installedBy: installedBy)
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let name = Self.binaryName(sha256: sha256)
        try await check("""
            set -e; d="$HOME/.agents-server"; ln -sfn \(Self.quote(name)) "$d/bin/current"; \
            printf '%s\\n' \(Self.quote(json)) > "$d/install.json.part"; mv "$d/install.json.part" "$d/install.json"
            """)
    }

    /// Delete every installed binary but this one. Called after a good connect on the
    /// new version, never in the same breath as the swap.
    public func removeBinaries(except sha256: String) async throws {
        let keep = Self.binaryName(sha256: sha256)
        try await check("""
            cd "$HOME/.agents-server/bin" && for f in agentsd-*; do \
            [ "$f" = \(Self.quote(keep)) ] || rm -f -- "$f"; done
            """)
    }

    // MARK: § 7 Start

    /// Start the server's daemon in the background. Returns once it has detached;
    /// readiness is the forward answering, which is `DaemonClient.connect`'s to wait for.
    public func startDaemon() async throws {
        try await check("""
            "$HOME/.agents-server/bin/current" --root "$HOME/.agents-server/root" --serve --detach
            """)
    }

    // MARK: § 8 Remove

    public func purge() async throws {
        try await check(#"rm -rf "$HOME/.agents-server""#)
    }

    // MARK: -

    private func run(_ script: String) async throws -> SSHCommand.Output {
        try await ssh.run(ssh.runArguments(script))
    }

    private func check(_ script: String) async throws {
        let out = try await run(script)
        guard out.status == 0 else {
            throw SSHCommand.classify(status: out.status, stderr: out.stderr, agentHasKeys: true)
                ?? .installFailed(out.stderr)
        }
    }

    /// One argument to the server's shell, whatever it contains. A Mac's name can have
    /// an apostrophe in it.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The SHA-256 of a local file, as `shasum` prints it.
    public static func sha256(of file: URL) async throws -> String {
        let shasum = SSHCommand(executable: URL(filePath: "/usr/bin/shasum"), name: "", controlPath: nil)
        let out = try await shasum.run(["-a", "256", file.path(percentEncoded: false)])
        guard out.status == 0, let sum = out.stdout.split(separator: " ").first else {
            throw HostProblem.installFailed(out.stderr)
        }
        return String(sum)
    }
}
