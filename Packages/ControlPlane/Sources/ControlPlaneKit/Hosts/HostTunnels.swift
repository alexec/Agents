import AgentsKit
import AgentsKitCore
import Foundation
#if canImport(Network)
import Network
#endif

/// Reverse tunnels for servers behind a bastion (#435), or for any server the person
/// asked for one (#610).
///
/// A host joins by dialling the control plane. A server this machine reaches only through
/// a `ProxyJump` or `ProxyCommand` can rarely dial back: nothing resolves or routes to this
/// Mac from there. For such a server `hosts/install` gives a code whose address is
/// `https://127.0.0.1:<port>` and leaves a record here; this holds `ssh -N -R` to it, so
/// that address on the server is this control plane's listener. The certificate is checked
/// by its pin, so the name does not matter.
///
/// - The session is the person's own ssh, with their config, agent and keys, and a known
///   hosts file holding only the key trusted at the install, or the person's own known_hosts
///   when the key was already there. No key is kept (#413): a key given for the install was
///   for the install.
/// - Only our forward rides it (#610): the config's `LocalForward`, `RemoteForward` and
///   `DynamicForward` are cleared, and a forward the server will not open ends the session
///   with ssh's reason.
/// - Held for as long as the server is a host: a session that drops is started again,
///   sooner the longer it had lasted, and at once when this Mac wakes or its network
///   changes. A record whose host was removed goes, and so does one whose host never joined.
/// - Only a single copy holds tunnels (Agents Host's): the ssh is this machine's.
public actor HostTunnels {
    public struct Record: Codable, Sendable, Equatable {
        public var id: String
        /// As typed: `user@host`, `user@host:port`, or a name from the ssh config.
        public var destination: String
        public var name: String
        /// The port on both ends: the server's loopback, this machine's listener.
        public var port: Int
        /// The host code's id: its spend says which host this carries.
        public var code: String
        public var host: HostID?
        /// The server's host key, as trusted at the install, in known_hosts form; empty when
        /// the person's own known_hosts had it (#610), which is then what the tunnel checks.
        public var knownHosts: String
        public var made: Date
    }

    static let prefix = "v1/tunnels/"
    static func key(_ id: String) -> String { "\(prefix)\(id).json" }
    /// A server that has not joined by then never will with that code.
    static let unjoinedKept: TimeInterval = ControlCode.lifetime + 10 * 60

    private let store: any ControlStore
    private let executable: URL
    private let environment: [String: String]
    /// `-F` and a config file, for tests; nothing, for the person's own.
    private let configFile: [String]
    private let hosts: @Sendable () async -> [HostRecord]
    private let changed: @Sendable (DaemonAPI.HostTunnelChanged) async -> Void
    private let log: @Sendable (String) -> Void
    private let folder: URL
    private var records: [String: Record] = [:]
    private var held: [String: Task<Void, Never>] = [:]
    private var states: [String: DaemonAPI.HostTunnel] = [:]
    private var ticker: Task<Void, Never>?
    #if canImport(Network)
    private var network: NWPathMonitor?
    private var lastPath: String?
    #endif

    public init(store: any ControlStore, executable: URL, environment: [String: String],
                hosts: @escaping @Sendable () async -> [HostRecord],
                changed: @escaping @Sendable (DaemonAPI.HostTunnelChanged) async -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in },
                configFile: [String] = HostInstall.configFile) {
        self.store = store
        self.executable = executable
        self.environment = environment
        self.configFile = configFile
        self.hosts = hosts
        self.changed = changed
        self.log = log
        // Short: a control socket's path must fit in 104 bytes, with ssh's own suffix.
        folder = URL(fileURLWithPath: "/tmp/agents-tunnels-\(getuid())-\(getpid())", isDirectory: true)
    }

    /// Takes up the records and keeps them true every `every`.
    /// A tick that took far longer on the clock that counts sleep than on the one that
    /// does not is this Mac waking: every session is started again then, not when
    /// `ServerAlive` gives up on a connection that died while it slept.
    public func start(every: Duration = .seconds(15)) {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                let (awake, wall) = (SuspendingClock.now, ContinuousClock.now)
                try? await Task.sleep(for: every)
                if (ContinuousClock.now - wall) - (SuspendingClock.now - awake) > .seconds(5) {
                    await self?.restart(because: "this Mac woke")
                }
            }
        }
        watchNetwork()
    }

    /// Every session started again now, the waits between tries forgotten.
    func restart(because why: String) {
        guard !held.isEmpty else { return }
        log("tunnels: \(why); starting every session again")
        for task in held.values { task.cancel() }
        held = [:]
        for record in records.values { hold(record) }
    }

    /// A new network (another Wi-Fi, a VPN, the cable) leaves every session on the old
    /// one: each is started again when the interfaces change, or the network comes back.
    private func watchNetwork() {
        #if canImport(Network)
        guard network == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let shape = path.status == .satisfied
                ? path.availableInterfaces.map { "\($0.name)" }.joined(separator: ",") : "none"
            Task { await self?.networkIs(shape) }
        }
        monitor.start(queue: DispatchQueue(label: "agents.tunnels.network"))
        network = monitor
        #endif
    }

    #if canImport(Network)
    private func networkIs(_ shape: String) {
        defer { lastPath = shape }
        guard let lastPath, lastPath != shape, shape != "none" else { return }
        restart(because: "the network changed")
    }
    #endif

    public func stop() {
        ticker?.cancel()
        ticker = nil
        #if canImport(Network)
        network?.cancel()
        network = nil
        #endif
        for task in held.values { task.cancel() }
        held = [:]
        try? FileManager.default.removeItem(at: folder)
    }

    /// A tunnel for a server just installed, held at once so its first dial finds it.
    public func add(_ record: Record) async throws {
        _ = try await store.put(Self.key(record.id), try ControlRecords.encoder.encode(record), when: .absent)
        records[record.id] = record
        hold(record)
    }

    /// How the tunnel for this host stands, or nil when it has none.
    public func state(for host: HostID) -> DaemonAPI.HostTunnel? {
        guard let record = records.values.first(where: { $0.host == host }) else { return nil }
        return states[record.id] ?? .init(up: false)
    }

    /// Reads the records again, learns which host each carries, lets go of those nobody
    /// needs, and holds the rest.
    func reconcile() async {
        guard let keys = try? await store.list(prefix: Self.prefix) else { return }
        var read: [String: Record] = [:]
        for key in keys.map(\.key) {
            guard let object = try? await store.get(key),
                  let record = try? ControlRecords.decoder.decode(Record.self, from: object.data) else { continue }
            read[record.id] = record
        }
        let known = await hosts()
        for var record in read.values {
            if record.host == nil, let host = await joined(record, known: known) {
                record.host = host
                // Only this copy writes tunnels, so nobody else's write can be lost.
                _ = try? await store.put(Self.key(record.id), try ControlRecords.encoder.encode(record), when: .always)
                read[record.id] = record
            }
            let gone = record.host.map { host in !known.contains { $0.id == host } }
                ?? (Date().timeIntervalSince(record.made) > Self.unjoinedKept)
            if gone {
                log("tunnel to \(record.name): no longer a host; letting go")
                try? await store.delete(Self.key(record.id))
                read[record.id] = nil
            }
        }
        records = read
        for id in held.keys where read[id] == nil {
            held.removeValue(forKey: id)?.cancel()
            states[id] = nil
        }
        for record in read.values where held[record.id] == nil { hold(record) }
    }

    /// The host that spent this record's code, or one of its name that no other tunnel
    /// carries, when the code has been swept.
    private func joined(_ record: Record, known: [HostRecord]) async -> HostID? {
        if let object = try? await store.get(ControlCodes.spentKey(record.code)),
           let spent = try? ControlRecords.decoder.decode(ControlCodes.Spent.self, from: object.data),
           let host = spent.host {
            return host
        }
        if (try? await store.get(ControlCodes.key(record.code))) == nil {
            let carried = Set(records.values.compactMap(\.host))
            return known.first { $0.name == record.name && !carried.contains($0.id) }?.id
        }
        return nil
    }

    // MARK: The ssh session

    private func hold(_ record: Record) {
        guard held[record.id] == nil else { return }
        var ssh = SSHCommand(executable: executable, name: record.destination, controlPath: nil, environment: environment)
        ssh.options = configFile
        let folder = self.folder
        held[record.id] = Task { [weak self] in
            var wait: TimeInterval = 2
            while !Task.isCancelled {
                let started = Date()
                let problem = await Self.session(record, ssh: ssh, folder: folder) { [weak self] in
                    await self?.say(record.id, .init(up: true))
                }
                guard !Task.isCancelled else { return }
                await self?.say(record.id, .init(up: false, problem: problem))
                // A session that lasted is tried again soon; one that keeps failing, less often.
                wait = Date().timeIntervalSince(started) > 60 ? 2 : min(wait * 2, 60)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func say(_ id: String, _ state: DaemonAPI.HostTunnel) async {
        guard let record = records[id], states[id] != state else { return }
        states[id] = state
        log("tunnel to \(record.name): \(state.up ? "up" : "down\(state.problem.map { ": \($0)" } ?? "")")")
        await changed(.init(name: record.name, host: record.host, tunnel: state))
    }

    /// One tunnel session, until it ends or the task is cancelled: why it ended, if ssh said.
    ///
    /// A master of its own with no forwards, then our one forward asked of it (#610): the
    /// master's `ClearAllForwardings` would drop a `-R` on its own command line. A forward
    /// the server refuses ends the session with ssh's words for it.
    static func session(_ record: Record, ssh base: SSHCommand, folder: URL,
                        up: @escaping @Sendable () async -> Void) async -> String? {
        var ssh = base
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return "its folder could not be made: \(error.localizedDescription)"
        }
        if record.knownHosts.isEmpty {
            ssh.options += await HostInstall.personsKnownHosts(ssh) + ["-o", "StrictHostKeyChecking=yes"]
        } else {
            let knownHosts = folder.appendingPathComponent("\(record.id).known_hosts")
            do {
                try Data(record.knownHosts.utf8).write(to: knownHosts, options: .atomic)
            } catch {
                return "its known hosts file could not be written: \(error.localizedDescription)"
            }
            ssh.options += ["-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
                            "-o", "StrictHostKeyChecking=yes"]
        }
        let control = folder.appendingPathComponent("\(record.id.prefix(8)).ctl")
        try? FileManager.default.removeItem(at: control)
        defer { try? FileManager.default.removeItem(at: control) }

        let process = Process()
        process.executableURL = ssh.executable
        process.arguments = ssh.tunnelMasterArguments(control: control)
        process.environment = ssh.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let heard = SessionLines()
        let forwarding = Task { () -> String? in
            await forward(record, ssh: ssh, control: control, master: process, up: up)
        }
        let ended = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                // ssh can exit before its last words are read: the session ends when it has
                // exited and its standard error is closed, or a moment after it exits if a
                // child of its own still holds that open.
                let ending = SessionEnding { problem in
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: problem ?? heard.problem ?? "the ssh session ended")
                }
                errors.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        ending.closed()
                    } else {
                        heard.take(data)
                    }
                }
                process.terminationHandler = { _ in
                    ending.exited()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { ending.end() }
                }
                do {
                    try process.run()
                    // Cancelled before it ran: the handler below found nothing to end.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    ending.end("ssh could not be started: \(error.localizedDescription)")
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
            forwarding.cancel()
        }
        forwarding.cancel()
        return await forwarding.value ?? ended
    }

    /// How long a master has to come up: ssh's own `ConnectTimeout` does not cover a
    /// `ProxyCommand` or a chain of jumps.
    static let connecting: Duration = .seconds(60)

    /// Once the master answers, ask it for the tunnel's forward. Why the session must end,
    /// or nil when the forward is open or the master ended by itself.
    private static func forward(_ record: Record, ssh: SSHCommand, control: URL, master: Process,
                                up: @Sendable () async -> Void) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + connecting
        // Not yet launched has no pid; launched and not running has ended.
        let ended = { master.processIdentifier != 0 && !master.isRunning }
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !ended() else { return nil }
            if master.processIdentifier != 0,
               let check = try? await ssh.run(ssh.tunnelControlArguments(control: control, "check")), check.status == 0 { break }
            if ended() { return nil }
            if clock.now > deadline {
                master.terminate()
                return "ssh did not connect within \(connecting.components.seconds) seconds"
            }
        }
        let asked = try? await ssh.run(ssh.tunnelForwardArguments(control: control, remotePort: record.port,
                                                                  localPort: record.port))
        if asked?.status == 0 {
            await up()
            return nil
        }
        // A master that ended meanwhile has its own reason.
        if ended() { return nil }
        master.terminate()
        return forwardFailure(asked?.stderr ?? "")
    }

    /// ssh's reason for a forward its master would not open: `mux_client_forward:
    /// forwarding request failed: remote port forwarding failed for listen port 8791`.
    static func forwardFailure(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let line = lines.first(where: { $0.contains("forwarding request failed: ") }),
           let range = line.range(of: "forwarding request failed: ") {
            return String(line[range.upperBound...])
        }
        return lines.compactMap(SessionLines.said).last ?? "the server would not open the tunnel's forward"
    }

    /// The end of one session: once ssh has exited and its standard error is closed, or
    /// when told to end outright. Ends once.
    final class SessionEnding: @unchecked Sendable {
        private let lock = NSLock()
        private var hasExited = false
        private var isClosed = false
        private var hasEnded = false
        private let finish: (String?) -> Void

        init(_ finish: @escaping (String?) -> Void) { self.finish = finish }

        func exited() { if lock.withLock({ hasExited = true; return isClosed }) { end() } }
        func closed() { if lock.withLock({ isClosed = true; return hasExited }) { end() } }

        func end(_ problem: String? = nil) {
            let first = lock.withLock { () -> Bool in
                defer { hasEnded = true }
                return !hasEnded
            }
            if first { finish(problem) }
        }
    }

    /// What ssh says on standard error, a line at a time: the last line that is not
    /// debug chatter is why it ended.
    final class SessionLines: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = Data()
        private var last: String?

        var problem: String? { lock.withLock { last } }

        func take(_ data: Data) {
            let lines: [String] = lock.withLock {
                partial.append(data)
                var out: [String] = []
                while let newline = partial.firstIndex(of: 0x0A) {
                    out.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
                    partial.removeSubrange(partial.startIndex...newline)
                }
                return out
            }
            for raw in lines {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if let said = Self.said(line) {
                    lock.withLock { last = said }
                }
            }
        }

        /// A line worth showing: ssh's own warnings and errors, not its debug output.
        static func said(_ line: String) -> String? {
            guard !line.isEmpty, !line.hasPrefix("debug"), !line.hasPrefix("OpenSSH_"),
                  !line.hasPrefix("Authenticated to"), !line.hasPrefix("Transferred:"),
                  !line.hasPrefix("Bytes per second") else { return nil }
            return line.hasPrefix("Warning: ") ? String(line.dropFirst("Warning: ".count)) : line
        }
    }
}
