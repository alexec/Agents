import AgentsKitCore
import Foundation

/// Servers the control plane installs and reaches over the person's own ssh (058, US3,
/// R9, T039–T041).
///
/// What the window's `HostSet` did, moved here so every client sees the result: the ssh
/// master and its forward, the install of the Linux `agentsd`, the host key's first
/// trust. Each connected server becomes a host of the router through an `SSHUplink` over
/// its forward. The control plane has no screen, so the first trust of a host key is a
/// question put back to the operator who asked (`needsTrust`), answered by asking again
/// with the fingerprint they saw.
actor SSHHosts {
    private let root: URL
    private let installedBy: String
    private weak var plane: ControlPlane?
    private var connections: [HostID: ServerConnection] = [:]
    private var uplinks: [HostID: SSHUplink] = [:]
    /// A host key fetched for somebody to look at, until they trust it or give up.
    private var fetched: [String: (HostKeyCheck.Fetched, HostKeyCheck.Resolved)] = [:]

    init(root: URL, installedBy: String) {
        self.root = root
        self.installedBy = installedBy
    }

    func attach(_ plane: ControlPlane) { self.plane = plane }

    private var folder: URL { root.appendingPathComponent("hosts", isDirectory: true) }

    private func ssh(_ destination: String, id: HostID) -> SSHCommand {
        let executable = ProcessInfo.processInfo.environment["AGENTS_SSH"].map { URL(filePath: $0) } ?? SSHCommand.system
        return SSHCommand(executable: executable, name: destination,
                          controlPath: folder.appendingPathComponent("\(id.rawValue).ctl"))
    }

    // MARK: hosts/install

    struct InstallRequest: Codable {
        /// What the person typed: `user@host`, `host`, a name from their ssh config.
        var destination: String
        /// The fingerprint they were shown and trust, on the second call.
        var trust: String?
    }

    /// Install and connect a server, then make it a host (FR-013).
    func install(_ params: JSONValue?) async throws -> JSONValue {
        guard let request = try? params?.decode(InstallRequest.self),
              let made = try? ServerHost(sshName: request.destination.trimmingCharacters(in: .whitespaces)) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That isn’t something ssh can connect to.")
        }
        if let known = await plane?.methods.allHosts.first(where: { record in
            if case .ssh(let destination, _) = record.reach { return destination == made.sshName }
            return false
        }) {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: "\(known.name) is already a host.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ssh = ssh(made.sshName, id: made.id)
        await progress(made.label, "connect")
        let resolved = try await Self.hostProblem { try await HostKeyCheck.resolve(ssh) }
        var fingerprint = await HostKeyCheck.knownFingerprint(resolved)
        if try await !(Self.hostProblem { try await HostKeyCheck.isKnown(resolved) }) {
            if let trusted = request.trust, let held = fetched[made.sshName], held.0.fingerprint == trusted {
                try await Self.hostProblem { try await HostKeyCheck.trust(held.0, into: held.1) }
                fetched[made.sshName] = nil
                fingerprint = trusted
            } else {
                let fresh = try await Self.hostProblem { try await HostKeyCheck.fetch(ssh) }
                fetched[made.sshName] = (fresh, resolved)
                return ["needsTrust": .string(fresh.fingerprint), "name": .string(made.label)]
            }
        }
        let record = HostRecord(id: made.id, name: made.label,
                                reach: .ssh(destination: made.sshName, hostKeyFingerprint: fingerprint),
                                installed: true)
        let connected = try await connect(record)
        return ["host": .string(record.id.rawValue), "name": .string(record.name), "platform": .string(connected.platform)]
    }

    /// Reach a server this control plane knows: at start, on Check again, after a drop.
    @discardableResult
    func connect(_ record: HostRecord) async throws -> HostRecord {
        guard case .ssh(let destination, _) = record.reach else { return record }
        let connection = connections[record.id] ?? ServerConnection(
            hostID: record.id, ssh: ssh(destination, id: record.id),
            socket: folder.appendingPathComponent("\(record.id.rawValue).sock"), installedBy: installedBy,
            binary: { await Self.binary(for: $0) })
        connections[record.id] = connection
        let name = record.name
        await connection.setOnState { [weak self] state in await self?.moved(record.id, name: name, to: state) }
        await connection.connect()
        let state = await connection.state
        guard case .connected = state else {
            if case .failed(let problem) = state {
                throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: "\(name): \(Self.words(problem))")
            }
            throw JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "\(name) could not be reached.")
        }
        var updated = record
        if let facts = await connection.facts {
            updated.platform = "\(facts.system) \(facts.architecture.display)"
            updated.version = facts.installedVersion ?? Self.version
        }
        try await plane?.methods.enroll(updated)
        return updated
    }

    /// The master's state moved: a host is online while its forward is, and not otherwise.
    private func moved(_ host: HostID, name: String, to state: ServerConnection.State) async {
        switch state {
        case .connecting(let step):
            await progress(name, step.rawValue)
        case .connected:
            await progress(name, "connected")
            uplinks[host]?.close()
            let uplink = SSHUplink(socket: folder.appendingPathComponent("\(host.rawValue).sock"))
            uplinks[host] = uplink
            await plane?.router.attachHost(host, transport: uplink)
        case .offline, .failed, .idle, .updateWaiting:
            uplinks.removeValue(forKey: host)?.close()
            if case .failed(let problem) = state {
                await plane?.router.setState(.failed(reason: Self.words(problem)), of: host)
            }
        }
    }

    func checkAgain(_ host: HostID) async throws {
        guard let record = await plane?.methods.host(host) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(host.rawValue).")
        }
        try await connect(record)
    }

    /// Hosts that are no longer on record are let go: their masters stop, their agents stay.
    func sync(_ records: [HostRecord]) async {
        let kept = Set(records.map(\.id))
        for (id, connection) in connections where !kept.contains(id) {
            uplinks.removeValue(forKey: id)?.close()
            await connection.disconnect()
            connections[id] = nil
        }
    }

    /// Every server on record, as the control plane starts.
    func reconnectAll(_ records: [HostRecord]) async {
        for record in records where record.reach.isSSH {
            Task { try? await self.connect(record) }
        }
    }

    private func progress(_ name: String, _ step: String) async {
        await plane?.router.broadcastControl(DaemonAPI.Notification.controlInstallProgress,
                                             ["name": .string(name), "step": .string(step)], operatorsOnly: true)
    }

    // MARK: What is installed

    /// The Linux binaries the app carries, in the app bundle this control plane is inside
    /// (`Agents.app/Contents/Helpers/agents-bridge.app`), or beside it in a build folder.
    static func binary(for architecture: Architecture) async -> ServerBinary? {
        if ProcessInfo.processInfo.environment["AGENTS_SSH"] != nil,
           let helper = helperAgentsd, let sha = try? await ServerInstaller.sha256(of: helper) {
            return ServerBinary(file: helper, sha256: sha, version: version)
        }
        guard let suffix = architecture.binarySuffix, let servers = serversFolder else { return nil }
        let file = servers.appendingPathComponent("agentsd-linux-\(suffix)")
        guard let sha = try? String(contentsOf: file.appendingPathExtension("sha256"), encoding: .utf8) else { return nil }
        return ServerBinary(file: file, sha256: sha.trimmingCharacters(in: .whitespacesAndNewlines), version: version)
    }

    private static var appBundle: URL? {
        var url = Bundle.main.bundleURL
        for _ in 0..<4 {
            if url.pathExtension == "app", url.lastPathComponent != Bundle.main.bundleURL.lastPathComponent { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static var serversFolder: URL? {
        [appBundle?.appendingPathComponent("Contents/Resources/servers"),
         Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Agents.app/Contents/Resources/servers")]
            .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var helperAgentsd: URL? {
        [appBundle?.appendingPathComponent("Contents/Helpers/agentsd"),
         Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Agents.app/Contents/Helpers/agentsd")]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var version: String {
        let info = (appBundle.flatMap(Bundle.init(url:)) ?? Bundle.main).infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(marketing)+\(build)"
    }

    // MARK: Words

    private static func hostProblem<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let problem as HostProblem {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: words(problem))
        }
    }

    static func words(_ problem: HostProblem) -> String {
        switch problem {
        case .unknownHost: "ssh doesn’t know that name."
        case .loginRefused: "The server refused the login."
        case .keyLocked: "The ssh key is locked. Unlock it with ssh-add, then try again."
        default: "\(problem)"
        }
    }
}
