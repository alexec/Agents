import AgentsKit
import AgentsKitCore
import Foundation

/// Reverse tunnels for servers behind a bastion (#435).
///
/// A host joins by dialling the control plane. A server this machine reaches only through
/// a `ProxyJump` or `ProxyCommand` can rarely dial back: nothing resolves or routes to this
/// Mac from there. For such a server `hosts/install` gives a code whose address is
/// `https://127.0.0.1:<port>` and leaves a record here; this holds `ssh -N -R` to it, so
/// that address on the server is this control plane's listener. The certificate is checked
/// by its pin, so the name does not matter.
///
/// - The session is the person's own ssh, with their config, agent and keys, and a known
///   hosts file holding only the key trusted at the install. No key is kept (#413): a key
///   given for the install was for the install.
/// - Held for as long as the server is a host: a session that drops is started again,
///   sooner the longer it had lasted. A record whose host was removed goes, and so does one
///   whose host never joined.
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
        /// The server's host key, as trusted at the install, in known_hosts form.
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
    private let hosts: @Sendable () async -> [HostRecord]
    private let changed: @Sendable (DaemonAPI.HostTunnelChanged) async -> Void
    private let log: @Sendable (String) -> Void
    private let folder: URL
    private var records: [String: Record] = [:]
    private var held: [String: Task<Void, Never>] = [:]
    private var states: [String: DaemonAPI.HostTunnel] = [:]
    private var ticker: Task<Void, Never>?

    public init(store: any ControlStore, executable: URL, environment: [String: String],
                hosts: @escaping @Sendable () async -> [HostRecord],
                changed: @escaping @Sendable (DaemonAPI.HostTunnelChanged) async -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.executable = executable
        self.environment = environment
        self.hosts = hosts
        self.changed = changed
        self.log = log
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("agents-tunnels-\(getpid())", isDirectory: true)
    }

    /// Takes up the records and keeps them true every `every`.
    public func start(every: Duration = .seconds(15)) {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: every)
            }
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
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
        let ssh = SSHCommand(executable: executable, name: record.destination, controlPath: nil, environment: environment)
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

    /// One `ssh -N -R`, until it ends or the task is cancelled: why it ended, if ssh said.
    static func session(_ record: Record, ssh base: SSHCommand, folder: URL,
                        up: @escaping @Sendable () async -> Void) async -> String? {
        let knownHosts = folder.appendingPathComponent("\(record.id).known_hosts")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(record.knownHosts.utf8).write(to: knownHosts, options: .atomic)
        } catch {
            return "its known hosts file could not be written: \(error.localizedDescription)"
        }
        var ssh = base
        ssh.options = ["-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
                       "-o", "StrictHostKeyChecking=yes"]
        let process = Process()
        process.executableURL = ssh.executable
        process.arguments = ssh.reverseTunnelArguments(remotePort: record.port, localPort: record.port)
        process.environment = ssh.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let heard = SessionLines(up: up)
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { heard.take(data) }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                process.terminationHandler = { _ in
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: heard.problem ?? "the ssh session ended")
                }
                do {
                    try process.run()
                    // Cancelled before it ran: the handler below found nothing to end.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: "ssh could not be started: \(error.localizedDescription)")
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// What ssh says on standard error, a line at a time: `remote forward success` is the
    /// tunnel open; the last line that is not `-v`'s own chatter is why it ended.
    final class SessionLines: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = Data()
        private var last: String?
        private let up: @Sendable () async -> Void

        init(up: @escaping @Sendable () async -> Void) { self.up = up }

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
                if line.contains("remote forward success") {
                    let up = self.up
                    Task { await up() }
                } else if let said = Self.said(line) {
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
