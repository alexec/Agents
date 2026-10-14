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
/// - The server's host key is checked against the person's known_hosts first (#610): one
///   already there is used as ssh would use it, and a changed one is refused. One not there
///   is shown (`needsTrust`) and trusted only when the fingerprint comes back; it goes into
///   the same folder, not the person's known_hosts.
/// - No master connection and no forward are kept (FR-018a). The host starts with a host
///   code and enrols over its own connection out, like one added by command.
/// - Except for a server that asks for a tunnel (#610), which by default is one the
///   person's ssh reaches through a bastion (`ProxyJump` or `ProxyCommand`) and can rarely
///   dial back (#435): its code's address is its own loopback, and `HostTunnels` holds a
///   reverse tunnel there for as long as it is a host. A server on the same network dials
///   the control plane's address, with no tunnel.
public struct HostInstall: Sendable {
    public struct Request: Codable, Sendable {
        /// `user@host`, `user@host:port`, or a name from the ssh config.
        public var destination: String
        public var name: String?
        /// The private key's text: OpenSSH or PEM. Nil or empty: ssh's own choice.
        public var key: String?
        /// The fingerprint the person was shown and trusts, on the second call.
        public var trust: String?
        /// Whether the server dials back through an ssh tunnel (#610). Nil: when ssh reaches
        /// it through a bastion.
        public var tunnel: Bool?

        public init(destination: String, name: String? = nil, key: String? = nil, trust: String? = nil,
                    tunnel: Bool? = nil) {
            self.destination = destination
            self.name = name
            self.key = key
            self.trust = trust
            self.tunnel = tunnel
        }
    }

    let codes: ControlCodes
    let servers: URL?
    /// Where a server behind a bastion's tunnel is held, and the port it reaches here;
    /// nil where this copy holds none (several copies, whose ssh is no person's).
    let tunnels: (holder: HostTunnels, port: Int)?
    let progress: @Sendable (String, String) async -> Void
    /// `-F` and a config file, for tests; nothing, for the person's own.
    let configFile: [String]

    public init(codes: ControlCodes, servers: URL?, tunnels: (holder: HostTunnels, port: Int)? = nil,
                configFile: [String] = HostInstall.configFile,
                progress: @escaping @Sendable (String, String) async -> Void = { _, _ in }) {
        self.codes = codes
        self.servers = servers
        self.tunnels = tunnels
        self.configFile = configFile
        self.progress = progress
    }

    public func run(_ params: JSONValue?) async throws -> JSONValue {
        guard let request = try? params?.decode(Request.self) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Say which server.")
        }
        return try await run(request)
    }

    /// The host key, in order (#610):
    /// 1. Without a fingerprint to trust, ssh logs in against the person's own known_hosts
    ///    with `StrictHostKeyChecking=yes`. A key there is the one they trust, so there is
    ///    nothing to show; a changed one is refused, as ssh refuses it.
    /// 2. No key there: it is fetched and its fingerprint returned (`needsTrust`).
    /// 3. With that fingerprint back, the key is fetched again into the install's own
    ///    known_hosts, checked against it, and the install goes on with that file.
    ///
    /// `personsKnownHosts`: a server found in the ssh config (#429), which ssh has just
    /// logged into that way; it never asks.
    func run(_ request: Request, personsKnownHosts: Bool = false) async throws -> JSONValue {
        guard !request.destination.trimmingCharacters(in: .whitespaces).isEmpty else {
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
        await progress(name, "connect")
        let trusting = request.trust.flatMap { $0.isEmpty || personsKnownHosts ? nil : $0 }
        let facts: ServerFacts
        if let trusting {
            // The key shown on the first call: fetched again, and used only if it is that one.
            ssh.options = configFile
            let fetched = try await Self.words(keyGiven: keyGiven) { try await HostKeyCheck.fetch(ssh) }
            defer { HostKeyCheck.discard(fetched) }
            guard trusting == fetched.fingerprint else {
                return ["needsTrust": .string(fetched.fingerprint), "name": .string(name)]
            }
            try FileManager.default.copyItem(at: fetched.file, to: knownHosts)
            ssh.options = configFile + Self.options(keyFile: keyFile, knownHosts: knownHosts)
            await progress(name, "checkSystem")
            facts = try await Self.words(keyGiven: keyGiven) { try await ServerInstaller(ssh: ssh).probe() }
        } else {
            ssh.options = configFile + Self.options(keyFile: keyFile, knownHosts: nil)
            ssh.options += await Self.personsKnownHosts(ssh)
            await progress(name, "checkSystem")
            do {
                facts = try await ServerInstaller(ssh: ssh).probe()
            } catch HostProblem.hostKeyUnknown where !personsKnownHosts {
                var fetching = ssh
                fetching.options = configFile
                let fetched = try await Self.words(keyGiven: keyGiven) { try await HostKeyCheck.fetch(fetching) }
                HostKeyCheck.discard(fetched)
                return ["needsTrust": .string(fetched.fingerprint), "name": .string(name)]
            } catch let problem as HostProblem {
                throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: Self.say(problem, keyGiven: keyGiven))
            }
        }
        let installer = ServerInstaller(ssh: ssh)
        guard let arch = facts.architecture.binarySuffix,
              let binary = ServerFiles.binary(for: arch, in: servers) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed,
                               message: "\(name) is \(facts.system) \(facts.architecture.display), which this control plane has no host for.")
        }
        await progress(name, "setUp")
        try await Self.words(keyGiven: keyGiven) { try await installer.install(binary: binary.file, sha256: binary.sha256, firstInstall: true) }
        try await Self.words(keyGiven: keyGiven) { try await installer.swapCurrent(to: binary.sha256, version: binary.version, installedBy: "control plane") }
        // The MCP servers Agents ships (#700), beside agentsd. One that fails to copy leaves the
        // host without it, not without a host.
        for server in ServerFiles.shippedServers(for: arch, in: servers) {
            try? await installer.installServer(named: server.name, binary: server.file, sha256: server.sha256)
        }
        // A host code, left in the host's root and read once: never on its command line,
        // where `ps` would show it. Through a tunnel, it names the server's end of the
        // tunnel, which is held from now so the host's first dial finds it (#435, #610).
        let code: String
        var tunnelled = false
        let wantsTunnel: Bool
        if let asked = request.tunnel { wantsTunnel = asked } else { wantsTunnel = await Self.throughBastion(ssh) }
        if wantsTunnel, tunnels == nil {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed,
                               message: "This control plane can’t hold an ssh tunnel: only one on your Mac can. Add the server without one.")
        }
        if wantsTunnel, let tunnels {
            let issued = try await codes.issue(.host, url: "https://127.0.0.1:\(tunnels.port)")
            let record = HostTunnels.Record(id: UUID().uuidString.lowercased(), destination: destination, name: name,
                                            port: tunnels.port, code: issued.id, host: nil,
                                            // Empty: the person's own known_hosts had the key.
                                            knownHosts: trusting == nil ? "" : (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? "",
                                            made: Date())
            try await tunnels.holder.add(record)
            code = issued.shown.text
            tunnelled = true
        } else {
            code = try await codes.issue(.host).text
        }
        try await Self.words(keyGiven: keyGiven) {
            try await installer.leaveJoinCode(code)
            try await installer.startDaemon(extra: ["--control-network", "--host-name", name])
        }
        await progress(name, "started")
        // The host enrols over its own connection; `control/hostChanged` says when it is on.
        return ["started": true, "name": .string(name), "platform": .string("\(facts.system) \(facts.architecture.display)"),
                "tunnel": .bool(tunnelled)]
    }

    /// Whether the person's ssh config reaches this server through another machine. A
    /// config ssh cannot read is taken as no bastion: the install says what went wrong.
    static func throughBastion(_ ssh: SSHCommand) async -> Bool {
        guard let resolved = try? await ssh.run(ssh.options + ssh.resolveArguments), resolved.status == 0 else { return false }
        return SSHCommand.throughBastion(resolved.stdout)
    }

    /// `agents@devbox.lan:2222` → `devbox.lan`.
    static func label(_ destination: String) -> String {
        var host = destination
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }

    /// `-F` and the file `AGENTS_SSH_CONFIG` names, for tests; otherwise ssh reads the
    /// person's own `~/.ssh/config`.
    public static var configFile: [String] {
        ProcessInfo.processInfo.environment["AGENTS_SSH_CONFIG"].map { ["-F", $0] } ?? []
    }

    static var sshExecutable: URL {
        ProcessInfo.processInfo.environment["AGENTS_SSH"].map { URL(fileURLWithPath: $0) } ?? SSHCommand.system
    }

    /// What ssh is told besides the person's config. The host key goes into the install's
    /// own known_hosts, or, for a server from the ssh config, is checked against the
    /// person's (#429). A key given is the only one tried; with none, ssh offers what it
    /// would for `ssh user@host` (#413). ssh's own errors are always said, over a config's
    /// `LogLevel quiet` (gh's, #964), so `HostProblem` hears why it failed.
    static func options(keyFile: URL?, knownHosts: URL?) -> [String] {
        let only = keyFile.map { ["-i", $0.path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none"] } ?? []
        let hosts = knownHosts.map { ["-o", "UserKnownHostsFile=\($0.path)", "-o", "GlobalKnownHostsFile=/dev/null"] } ?? []
        return only + hosts + ["-o", "StrictHostKeyChecking=yes"] + sayErrors
    }

    /// Over a config's `LogLevel quiet`, which keeps even "Host key verification failed" off
    /// standard error (#964).
    static let sayErrors = ["-o", "LogLevel=error"]

    /// The person's own known_hosts, for a server whose ssh config checks against none:
    /// `UserKnownHostsFile /dev/null`, as generated configs often write beside
    /// `StrictHostKeyChecking no` (#514). Checking a key against /dev/null always fails, so
    /// ssh's default files are named instead. A config that names real files keeps them.
    static func personsKnownHosts(_ ssh: SSHCommand) async -> [String] {
        guard let resolved = try? await ssh.run(ssh.options + ssh.resolveArguments), resolved.status == 0 else { return [] }
        return knownHostsOverride(resolved: resolved.stdout)
    }

    /// From `ssh -G` output: the default known_hosts files when every one it names is
    /// /dev/null, otherwise nothing.
    static func knownHostsOverride(resolved: String) -> [String] {
        var files: [Substring] = []
        for line in resolved.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "userknownhostsfile" else { continue }
            files = parts[1].split(separator: " ")
            break
        }
        guard !files.isEmpty, files.allSatisfy({ $0 == "/dev/null" }) else { return [] }
        return ["-o", "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts2"]
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
        case .hostKeyChanged:
            "The server’s host key has changed since your known_hosts last saw it, so nothing was installed. If the server was rebuilt, remove its old key (ssh-keygen -R) and try again."
        case .hostKeyUnknown:
            "The server’s host key isn’t in your known_hosts. Add it over ssh to see the key and trust it."
        case .timedOut: "It did not answer: the connection timed out or was refused."
        case .installFailed(let words) where words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            "ssh failed without saying why."
        case .installFailed(let words): words
        default: "\(problem)"
        }
    }
}
