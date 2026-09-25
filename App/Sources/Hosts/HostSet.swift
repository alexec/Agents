import AgentsKit
import AppKit
import Foundation
import Network
import Observation

/// Every server this window reaches, and how each is doing (037).
///
/// This Mac is not in here: its daemon is `AppModel`'s own client, as it always was.
/// Each server is a `ServerConnection`, which does the work of getting from nothing to
/// a daemon answering; this keeps them going, retries the ones that have gone, and
/// hands what each server says to the window with its host attached.
///
/// Retrying backs off from a second to half a minute, and goes again at once when the
/// Mac wakes or its network comes back, which is when a server most likely returned.
@MainActor
@Observable
final class HostSet {
    private(set) var hosts: HostList
    private(set) var states: [HostID: ServerConnection.State] = [:]
    /// When the next attempt is due, for the offline strip's countdown.
    private(set) var nextTry: [HostID: Date] = [:]

    @ObservationIgnored private var connections: [HostID: ServerConnection] = [:]
    @ObservationIgnored private var listening: [HostID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retrying: [HostID: Task<Void, Never>] = [:]
    @ObservationIgnored private let store: HostStore
    @ObservationIgnored private let locations: StoreLocations
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// What a server said, and which one said it.
    @ObservationIgnored var onNotification: ((HostID, String, JSONValue?) async -> Void)?
    /// A server has just become reachable: the window lists what it has.
    @ObservationIgnored var onConnected: ((HostID) async -> Void)?

    init(locations: StoreLocations) {
        self.locations = locations
        self.store = HostStore(locations: locations)
        self.hosts = store.load()
    }

    var isEmpty: Bool { hosts.all.isEmpty }

    func host(_ id: HostID) -> ServerHost? { hosts[id] }

    func label(_ id: HostID) -> String {
        id == .mac ? "This Mac" : hosts[id]?.label ?? "a server"
    }

    func state(_ id: HostID) -> ServerConnection.State {
        id == .mac ? .connected : states[id] ?? .idle
    }

    func isOffline(_ id: HostID) -> Bool {
        guard id != .mac else { return false }
        if case .connected = state(id) { return false }
        return true
    }

    /// The client for a server. Calls on it throw at once while it is not connected,
    /// which is the offline answer the window wants.
    func client(for id: HostID) -> DaemonClient? {
        connections[id]?.client
    }

    // MARK: Starting and stopping

    /// Connect to every server, and start watching for the moments worth retrying in.
    func start() {
        watchForReturns()
        for host in hosts.all { connect(host.id) }
    }

    func connect(_ id: HostID) {
        guard let host = hosts[id] else { return }
        let connection = connections[id] ?? makeConnection(host)
        connections[id] = connection
        retrying[id]?.cancel()
        retrying[id] = nil
        Task { await connection.connect() }
    }

    /// Try every server that is not connected, now.
    func retryNow() {
        for host in hosts.all where isOffline(host.id) {
            if case .failed = state(host.id) { continue }
            connect(host.id)
        }
    }

    /// A server the Add a server sheet has just set up. Recorded, and kept connected.
    func add(_ host: ServerHost, connection: ServerConnection) {
        try? hosts.add(host)
        try? store.save(hosts)
        connections[host.id] = connection
        Task {
            await connection.setOnState { [weak self] state in
                await self?.moved(host.id, to: state)
            }
            await self.moved(host.id, to: connection.state)
        }
    }

    func update(_ host: ServerHost) {
        hosts.update(host)
        try? store.save(hosts)
    }

    /// Stop talking to a server and forget it. What happens on the server is the
    /// caller's to have done first (`ServerInstaller.purge`, `daemon/quit`).
    func remove(_ id: HostID) async {
        listening[id]?.cancel()
        retrying[id]?.cancel()
        await connections[id]?.disconnect()
        connections[id] = nil
        states[id] = nil
        hosts.remove(id)
        try? store.save(hosts)
    }

    // MARK: -

    private func makeConnection(_ host: ServerHost) -> ServerConnection {
        let hostsFolder = locations.hostsFolder
        var ssh = SSHCommand(executable: Self.sshExecutable, name: host.sshName,
                             controlPath: hostsFolder.appendingPathComponent("\(host.id.rawValue).ctl"))
        ssh.environment = SSHCommand.environment(from: ProcessInfo.processInfo.environment)
        let connection = ServerConnection(hostID: host.id, ssh: ssh,
                                          socket: hostsFolder.appendingPathComponent("\(host.id.rawValue).sock"),
                                          installedBy: ServerHost.currentMacName,
                                          binary: { await ServerBinaries.binary(for: $0) })
        Task {
            await connection.setOnState { [weak self] state in
                await self?.moved(host.id, to: state)
            }
        }
        return connection
    }

    private func moved(_ id: HostID, to state: ServerConnection.State) async {
        states[id] = state
        switch state {
        case .connected:
            nextTry[id] = nil
            if let facts = await connections[id]?.facts, var host = hosts[id] {
                host.facts = facts
                update(host)
            }
            listen(id)
            await onConnected?(id)
        case .offline:
            listening[id]?.cancel()
            scheduleRetry(id)
        default:
            break
        }
    }

    private func listen(_ id: HostID) {
        listening[id]?.cancel()
        guard let client = connections[id]?.client else { return }
        let notifications = client.notifications()
        listening[id] = Task.detached(priority: .userInitiated) { [weak self] in
            for await notification in notifications {
                await self?.forward(id, notification.method, notification.params)
            }
        }
    }

    private func forward(_ id: HostID, _ method: String, _ params: JSONValue?) async {
        await onNotification?(id, method, params)
    }

    private func scheduleRetry(_ id: HostID, after wait: Duration = .seconds(1)) {
        retrying[id]?.cancel()
        nextTry[id] = Date().addingTimeInterval(TimeInterval(wait.components.seconds))
        retrying[id] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let connection = self.connections[id] else { return }
            await connection.connect()
            if self.isOffline(id), case .offline = self.state(id) {
                self.scheduleRetry(id, after: min(wait * 2, .seconds(30)))
            }
        }
    }

    private func watchForReturns() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.retryNow() }
        }
        monitor.start(queue: DispatchQueue(label: "com.alexecollins.agents.hosts.path"))
        pathMonitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retryNow() }
        }
    }

    /// `/usr/bin/ssh`, or `AGENTS_SSH` for the fake one a scratch walk uses.
    static var sshExecutable: URL {
        ProcessInfo.processInfo.environment["AGENTS_SSH"].map { URL(filePath: $0) } ?? SSHCommand.system
    }
}

extension ServerHost {
    /// What `install.json` records as who installed it: this Mac's name.
    static var currentMacName: String {
        Foundation.Host.current().localizedName ?? "a Mac"
    }
}

/// The Linux binaries the app carries, from `scripts/build-linux-agentsd.sh` (037).
enum ServerBinaries {
    static func binary(for architecture: Architecture) async -> ServerBinary? {
        // A scratch walk against the fake ssh runs this Mac's own agentsd as the
        // "server", since the fake server is a folder on this Mac.
        if ProcessInfo.processInfo.environment["AGENTS_SSH"] != nil {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentsd")
            guard let sha = try? await ServerInstaller.sha256(of: helper) else { return nil }
            return ServerBinary(file: helper, sha256: sha, version: version)
        }
        guard let suffix = architecture.binarySuffix,
              let file = Bundle.main.url(forResource: "agentsd-linux-\(suffix)", withExtension: nil,
                                         subdirectory: "servers"),
              let sha = try? String(contentsOf: file.appendingPathExtension("sha256"), encoding: .utf8)
        else { return nil }
        return ServerBinary(file: file, sha256: sha.trimmingCharacters(in: .whitespacesAndNewlines), version: version)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(marketing)+\(build)"
    }
}
