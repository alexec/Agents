import AgentsKitCore
import Foundation

/// Servers the first build's control plane installs over the person's own ssh (058,
/// T039–T041). Every one connects out afterwards (T073): the ssh is for the install and
/// for starting the daemon again, and no master or forward is kept. The control plane has
/// no screen, so the first trust of a host key is a question put back to the operator who
/// asked (`needsTrust`), answered by asking again with the fingerprint they saw.
actor SSHHosts {
    private let root: URL
    private let installedBy: String
    private weak var plane: ControlPlane?
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
        loadDialOuts()
        if let known = await plane?.methods.allHosts.first(where: { dialOuts[$0.id.rawValue]?.destination == made.sshName }) {
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
        if let dialled = try await enrolByDialling(made, fingerprint: fingerprint) { return dialled }
        throw JSONRPCError(code: DaemonAPI.Failure.hostOffline,
                           message: "\(made.label) installed, but could not reach the control plane. It has to be able to connect out to it.")
    }

    func checkAgain(_ host: HostID) async throws {
        guard let record = await plane?.methods.host(host) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchHost, message: "No host is called \(host.rawValue).")
        }
        _ = record
        loadDialOuts()
        guard let dial = dialOuts[host.rawValue] else { return }
        try await startDialOut(dial, host: host, name: record.name)
    }

    /// Hosts that are no longer on record are let go; their agents stay.
    func sync(_ records: [HostRecord]) async {
        let kept = Set(records.map(\.id))
        loadDialOuts()
        let before = dialOuts.count
        dialOuts = dialOuts.filter { kept.contains(HostID(rawValue: $0.key)) }
        if dialOuts.count != before { saveDialOuts() }
    }

    /// Every server on record, as the control plane starts.
    func reconnectAll(_ records: [HostRecord]) async {
        loadDialOuts()
        for record in records {
            guard let dial = dialOuts[record.id.rawValue] else { continue }
            let name = record.name
            Task { try? await self.startDialOut(dial, host: record.id, name: name) }
        }
    }

    /// Install the binary and start the daemon with a host code. If it dials in, it is a
    /// dial-out host and the ssh master is let go. If it cannot reach the control plane,
    /// the daemon is stopped and the caller reaches it over ssh instead (FR-013, T044).
    private func enrolByDialling(_ made: ServerHost, fingerprint: String?) async throws -> JSONValue? {
        guard let code = await plane?.enrolmentCode() else { return nil }
        let before = Set(await plane?.methods.allHosts.map(\.id) ?? [])
        let attempt = ServerConnection(
            hostID: made.id, ssh: ssh(made.sshName, id: made.id),
            socket: folder.appendingPathComponent("\(made.id.rawValue).sock"), installedBy: installedBy,
            binary: { await Self.binary(for: $0) })
        await attempt.setLaunchArguments(["--control-code", code, "--host-name", made.label])
        await attempt.setOnState { [weak self] state in
            if case .connecting(let step) = state { await self?.progress(made.label, step.rawValue) }
        }
        await attempt.connect()
        guard case .connected = await attempt.state else {
            if case .failed(let problem) = await attempt.state {
                throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: "\(made.label): \(Self.words(problem))")
            }
            throw JSONRPCError(code: DaemonAPI.Failure.hostOffline, message: "\(made.label) could not be reached.")
        }
        if let found = await waitForDialOut(named: made.label, notIn: before) {
            var record = found
            record.installed = true
            record.name = made.label
            try await plane?.methods.enroll(record)
            dialOuts[record.id.rawValue] = DialOut(destination: made.sshName, fingerprint: fingerprint)
            saveDialOuts()
            await attempt.disconnect()
            await plane?.router.broadcastControl(DaemonAPI.Notification.controlHostChanged,
                                                 ControlRouter.describe(record.id, .online))
            return ["host": .string(record.id.rawValue), "name": .string(record.name),
                    "platform": .string(record.platform)]
        }
        await attempt.stopDaemon()
        await attempt.disconnect()
        return nil
    }

    /// A new host of this name, enrolled by the code we just handed the server.
    private func waitForDialOut(named name: String, notIn before: Set<HostID>) async -> HostRecord? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        var seen: HostRecord?
        while ContinuousClock.now < deadline {
            let hosts = await plane?.methods.allHosts ?? []
            if let found = hosts.first(where: { !before.contains($0.id) && $0.name == name }) {
                seen = found
                if await plane?.router.state(of: found.id)?.isOnline == true {
                    return await plane?.methods.host(found.id) ?? found
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return seen
    }

    /// Start a dial-out daemon that already enrolled. A fresh ssh, not a master: if the
    /// process is up it returns at once, and if the machine rebooted this brings it back.
    private func startDialOut(_ dial: DialOut, host: HostID, name: String) async throws {
        var command = ssh(dial.destination, id: host)
        command.controlPath = nil
        try await ServerInstaller(ssh: command).startDaemon(extra: ["--control-network", "--host-name", name])
    }

    private struct DialOut: Codable {
        var destination: String
        var fingerprint: String?
    }

    private var dialOuts: [String: DialOut] = [:]
    private var dialOutsLoaded = false
    private var dialOutFile: URL { folder.appendingPathComponent("dial-out.json") }

    private func loadDialOuts() {
        guard !dialOutsLoaded else { return }
        dialOutsLoaded = true
        guard let data = try? Data(contentsOf: dialOutFile),
              let decoded = try? JSONDecoder().decode([String: DialOut].self, from: data) else { return }
        dialOuts = decoded
    }

    private func saveDialOuts() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(dialOuts) else { return }
        try? data.write(to: dialOutFile, options: .atomic)
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
