import AgentsKitCore
import Foundation

/// A server's key, checked the way ssh will check it (037, contracts/ssh.md §§ 1–3).
///
/// `ssh-keyscan` would be simpler and would be wrong behind a jump host: it ignores the
/// person's config and asks whatever the name resolves to directly. So ssh itself
/// fetches the key, through their config, offering no credentials, into a temporary
/// file; the window shows its fingerprint; and only when the person says so is it added
/// to their own known hosts. A key that has *changed* is never offered this way: ssh
/// refuses it, and the window says so and stops.
public enum HostKeyCheck {
    /// What `ssh -G` says about a name.
    public struct Resolved: Sendable, Equatable {
        public var hostname: String
        public var port: Int
        public var knownHostsFiles: [String]
        public var hashKnownHosts: Bool

        /// How `known_hosts` spells the host: bare for port 22, `[host]:port` otherwise.
        public var lookupName: String { port == 22 ? hostname : "[\(hostname)]:\(port)" }
    }

    /// A key fetched and waiting to be trusted or thrown away.
    public struct Fetched: Sendable, Equatable {
        public var file: URL
        public var fingerprint: String
    }

    static let keygen = URL(filePath: "/usr/bin/ssh-keygen")

    public static func resolve(_ ssh: SSHCommand) async throws -> Resolved {
        let out = try await ssh.run(ssh.resolveArguments)
        guard out.status == 0 else {
            throw SSHCommand.classify(status: out.status, stderr: out.stderr, agentHasKeys: true) ?? .unknownHost
        }
        var resolved = Resolved(hostname: ssh.name, port: 22, knownHostsFiles: [], hashKnownHosts: false)
        for line in out.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "hostname": resolved.hostname = parts[1]
            case "port": resolved.port = Int(parts[1]) ?? 22
            case "userknownhostsfile":
                resolved.knownHostsFiles = parts[1].split(separator: " ").map {
                    (String($0) as NSString).expandingTildeInPath
                }
            case "hashknownhosts": resolved.hashKnownHosts = parts[1] == "yes"
            default: break
            }
        }
        return resolved
    }

    /// Whether any of the person's known-hosts files already has a key for this host.
    public static func isKnown(_ resolved: Resolved) async throws -> Bool {
        let keygen = SSHCommand(executable: keygen, name: "", controlPath: nil)
        for file in resolved.knownHostsFiles where FileManager.default.fileExists(atPath: file) {
            let out = try await keygen.run(["-F", resolved.lookupName, "-f", file])
            if out.status == 0, !out.stdout.isEmpty { return true }
        }
        return false
    }

    /// Connect only far enough to be shown the key, and read its SHA-256 fingerprint.
    /// The connection is expected to fail at authentication; what matters is that the
    /// key was written down first.
    public static func fetch(_ ssh: SSHCommand) async throws -> Fetched {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hostkey-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let out = try await ssh.run(ssh.keyFetchArguments(knownHosts: file))
        let written = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? FileManager.default.removeItem(at: file)
            let hasKeys = await SSHCommand.agentHasKeys(environment: ssh.environment)
            throw SSHCommand.classify(status: out.status == 0 ? 255 : out.status, stderr: out.stderr,
                                      agentHasKeys: hasKeys) ?? .installFailed(out.stderr)
        }
        let keygen = SSHCommand(executable: keygen, name: "", controlPath: nil)
        let print = try await keygen.run(["-lf", file.path, "-E", "sha256"])
        guard let fingerprint = print.stdout.split(separator: " ").first(where: { $0.hasPrefix("SHA256:") }) else {
            try? FileManager.default.removeItem(at: file)
            throw HostProblem.installFailed(print.stderr)
        }
        return Fetched(file: file, fingerprint: String(fingerprint))
    }

    /// Add the fetched key to the person's first known-hosts file, hashed if their
    /// config hashes, and remove the temporary file.
    public static func trust(_ fetched: Fetched, into resolved: Resolved) async throws {
        defer { discard(fetched) }
        guard let target = resolved.knownHostsFiles.first else { throw HostProblem.installFailed("no known_hosts file") }
        if resolved.hashKnownHosts {
            let keygen = SSHCommand(executable: keygen, name: "", controlPath: nil)
            _ = try await keygen.run(["-H", "-f", fetched.file.path])
            try? FileManager.default.removeItem(atPath: fetched.file.path + ".old")
        }
        var lines = try String(contentsOf: fetched.file, encoding: .utf8)
        if !lines.hasSuffix("\n") { lines += "\n" }
        let targetURL = URL(filePath: target)
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: target) {
            FileManager.default.createFile(atPath: target, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: targetURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        // A file that does not end in a newline would glue the new key to its last line.
        if let size = try? handle.offset(), size > 0,
           let last = try? Data(contentsOf: targetURL).last, last != UInt8(ascii: "\n") {
            try handle.write(contentsOf: Data("\n".utf8))
        }
        try handle.write(contentsOf: Data(lines.utf8))
    }

    public static func discard(_ fetched: Fetched) {
        try? FileManager.default.removeItem(at: fetched.file)
        try? FileManager.default.removeItem(atPath: fetched.file.path + ".old")
    }
}
