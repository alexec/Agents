import AgentsKit
import AgentsKitCore
import Foundation

/// `hosts/install` (058, US4, T072; frame M2): the control plane installs the host on a
/// server the person can ssh to, once, and lets go.
///
/// - A key, when one comes in the request, lives for this call only: written 0600 into a
///   folder of its own and handed to `ssh -i`, with the folder removed on every way out.
///   With none, ssh logs in as `ssh user@host` would for the person running the control
///   plane: their agent, `~/.ssh/config` and default identity (#413). Only a control plane
///   on the person's own Mac has those; one elsewhere needs the key.
/// - The server's host key is shown first (`needsTrust`) and trusted only when the
///   fingerprint comes back; it goes into the same folder, not the person's known_hosts.
/// - No master connection and no forward are kept (FR-018a). The host starts with a host
///   code and enrols over its own connection out, like one added by command.
public struct HostInstall: Sendable {
    public struct Request: Codable, Sendable {
        /// `user@host`, `user@host:port`, or a name from the ssh config.
        public var destination: String
        public var name: String?
        /// The private key's text: OpenSSH or PEM. Nil or empty: ssh's own choice.
        public var key: String?
        /// The fingerprint the person was shown and trusts, on the second call.
        public var trust: String?
    }

    let codes: ControlCodes
    let servers: URL?
    let progress: @Sendable (String, String) async -> Void

    public init(codes: ControlCodes, servers: URL?, progress: @escaping @Sendable (String, String) async -> Void = { _, _ in }) {
        self.codes = codes
        self.servers = servers
        self.progress = progress
    }

    public func run(_ params: JSONValue?) async throws -> JSONValue {
        guard let request = try? params?.decode(Request.self),
              !request.destination.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Say which server.")
        }
        let key = request.key.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let destination = request.destination.trimmingCharacters(in: .whitespaces)
        let name = request.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? Self.label(destination)

        // One folder for everything this install touches, gone however the call ends.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var keyFile: URL?
        if let key {
            let file = folder.appendingPathComponent("key")
            let keyText = key.hasSuffix("\n") ? key : key + "\n"
            guard FileManager.default.createFile(atPath: file.path, contents: Data(keyText.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw JSONRPCError(code: JSONRPCError.internalError, message: "The key could not be held for the install.")
            }
            keyFile = file
        }
        let knownHosts = folder.appendingPathComponent("known_hosts")
        let keyGiven = keyFile != nil

        var ssh = SSHCommand(executable: Self.sshExecutable, name: destination, controlPath: nil,
                             environment: Self.environment(keepAgent: !keyGiven))
        ssh.options = Self.options(keyFile: keyFile, knownHosts: knownHosts)

        // The host key: shown once, trusted when its fingerprint comes back.
        await progress(name, "connect")
        let fetched = try await Self.words(keyGiven: keyGiven) { try await HostKeyCheck.fetch(ssh) }
        defer { HostKeyCheck.discard(fetched) }
        guard let trust = request.trust, trust == fetched.fingerprint else {
            return ["needsTrust": .string(fetched.fingerprint), "name": .string(name)]
        }
        try FileManager.default.copyItem(at: fetched.file, to: knownHosts)

        let installer = ServerInstaller(ssh: ssh)
        await progress(name, "checkSystem")
        let facts = try await Self.words(keyGiven: keyGiven) { try await installer.probe() }
        guard let arch = facts.architecture.binarySuffix,
              let binary = ServerFiles.binary(for: arch, in: servers) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed,
                               message: "\(name) is \(facts.system) \(facts.architecture.display), which this control plane has no host for.")
        }
        await progress(name, "setUp")
        try await Self.words(keyGiven: keyGiven) { try await installer.install(binary: binary.file, sha256: binary.sha256, firstInstall: true) }
        try await Self.words(keyGiven: keyGiven) { try await installer.swapCurrent(to: binary.sha256, version: binary.version, installedBy: "control plane") }
        // A host code, left in the host's root and read once: never on its command line,
        // where `ps` would show it.
        let code = try await codes.issue(.host).text
        try await Self.words(keyGiven: keyGiven) {
            try await installer.leaveJoinCode(code)
            try await installer.startDaemon(extra: ["--control-network", "--host-name", name])
        }
        await progress(name, "started")
        // The host enrols over its own connection; `control/hostChanged` says when it is on.
        return ["started": true, "name": .string(name), "platform": .string("\(facts.system) \(facts.architecture.display)")]
    }

    /// `agents@devbox.lan:2222` → `devbox.lan`.
    static func label(_ destination: String) -> String {
        var host = destination
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }

    static var sshExecutable: URL {
        ProcessInfo.processInfo.environment["AGENTS_SSH"].map { URL(fileURLWithPath: $0) } ?? SSHCommand.system
    }

    /// What ssh is told besides the person's config. The host key always goes into the
    /// install's own known_hosts. A key given is the only one tried; with none, ssh
    /// offers what it would for `ssh user@host` (#413).
    static func options(keyFile: URL?, knownHosts: URL) -> [String] {
        let only = keyFile.map { ["-i", $0.path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none"] } ?? []
        return only + ["-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
                       "-o", "StrictHostKeyChecking=yes"]
    }

    /// What ssh runs with: nothing of this process's own. The agent stays only when no key
    /// was given, so a refused key is never followed by another identity.
    static func environment(keepAgent: Bool, from inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = SSHCommand.environment(from: inherited)
        if !keepAgent { environment["SSH_AUTH_SOCK"] = nil }
        return environment
    }

    private static func words<T>(keyGiven: Bool, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let problem as HostProblem {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: Self.say(problem, keyGiven: keyGiven))
        }
    }

    static func say(_ problem: HostProblem, keyGiven: Bool = true) -> String {
        switch problem {
        case .unknownHost: "ssh doesn’t know that server."
        case .loginRefused where !keyGiven, .keyLocked where !keyGiven:
            "The server refused every key ssh offered. If yours has a passphrase, add it to the agent (ssh-add), or choose a key."
        case .loginRefused: "The server refused that key."
        case .keyLocked: "That key has a passphrase. Give a key without one for the install, or run the command instead."
        default: "\(problem)"
        }
    }
}
