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
    /// Projects a server had and no longer has: rebuilt or wiped under them (043, FR-019).
    private(set) var goneProjects: [HostID: [String]] = [:]
    /// A server whose key changed, waiting on the person to say whether it was rebuilt (043).
    var rebuiltAsk: HostID?
    /// Claude's toolset on each server (043).
    private(set) var claude: [HostID: ServerConnection.Claude] = [:]
    /// Whether a server should get Claude as it connects: the window has a credential it
    /// may lend there (043, FR-002). Set by `AppModel`, which knows the credentials.
    @ObservationIgnored var claudeWanted: (HostID) -> Bool = { _ in false }
    /// What a server may be lent from this window, and who answers when it asks (043).
    @ObservationIgnored var offerFor: (HostID) -> DaemonAPI.CredentialsOffer? = { _ in nil }
    @ObservationIgnored var lenderFor: (HostID) -> DaemonClient.CredentialLender? = { _ in nil }

    @ObservationIgnored private var connections: [HostID: ServerConnection] = [:]
    @ObservationIgnored private var listening: [HostID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retrying: [HostID: Task<Void, Never>] = [:]
    @ObservationIgnored private let store: HostStore
    @ObservationIgnored private let locations: StoreLocations
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?

    /// Quitting: every ssh master goes with the window. The servers' daemons, and the
    /// agents on them, carry on.
    func stopForQuit() {
        for connection in connections.values { connection.stopForQuit() }
    }

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

    /// Since when a server that was connected has been gone. Kept through the retries,
    /// so the heading says Offline and since when rather than flickering to a spinner
    /// every time the window tries again (037, ui.md § Offline).
    private(set) var reachability = ServerReachability()
    var offlineSince: [HostID: Date] { reachability.offlineSince }
    /// A server went offline (`false`) or came back (`true`): the daemon raises it as
    /// `server.offline` or `server.online`, so agents and workflows can wait on it (042).
    @ObservationIgnored var onReachability: ((String, Bool) async -> Void)?

    func state(_ id: HostID) -> ServerConnection.State {
        guard id != .mac else { return .connected }
        let state = states[id] ?? .idle
        if case .connecting = state, let since = offlineSince[id] { return .offline(since: since) }
        return state
    }

    func isOffline(_ id: HostID) -> Bool {
        guard id != .mac else { return false }
        switch state(id) {
        // Waiting to update is still talking to the old daemon, which is fine to use.
        case .connected, .updateWaiting: return false
        default: return true
        }
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
        log("\(host.label): connecting")
        let connection = connections[id] ?? makeConnection(host)
        connections[id] = connection
        retrying[id]?.cancel()
        retrying[id] = nil
        Task { await connection.connect() }
    }

    /// Try every server that is not connected, now.
    func retryNow() {
        for host in hosts.all where isOffline(host.id) {
            if case .failed = states[host.id] { continue }
            if case .connecting = states[host.id] { continue }
            connect(host.id)
        }
    }

    /// A server the Add a server sheet has just set up. Recorded, and kept connected.
    func add(_ host: ServerHost, connection: ServerConnection) {
        try? hosts.add(host)
        try? store.save(hosts)
        connections[host.id] = connection
        follow(host.id, connection)
        Task { await self.moved(host.id, to: connection.state) }
    }

    func update(_ host: ServerHost) {
        hosts.update(host)
        try? store.save(hosts)
    }

    /// "Use this server's own sign-in only" (043, FR-014). Takes effect on the next
    /// connect, which is at once: the window tells the server what it may be lent then.
    func setOwnSignInOnly(_ id: HostID, _ on: Bool) {
        guard var host = hosts[id], host.ownSignInOnly != on else { return }
        host.ownSignInOnly = on
        update(host)
        connect(id)
    }

    /// How Claude stands on a server, in one line for Settings (043, contracts/ui.md § 2).
    func claudeLine(_ id: HostID, hasCredential: Bool) -> String {
        guard let host = hosts[id], let facts = host.facts else { return "Claude: not checked yet" }
        switch claude[id] {
        case .installing: return "Claude: installing…"
        case .updateWaiting: return "Claude: update waiting for a turn to end"
        case .failed(let problem): return problem.sentence(name: host.sshName, label: host.label)
        default: break
        }
        let signIn = host.ownSignInOnly ? " · its own sign-in only"
            : hasCredential ? " · signs in with the token in Settings"
            : facts.hasOwnClaudeSignIn ? " · its own sign-in" : " · needs a token"
        if facts.toolsetID != nil { return "Claude: ready (installed by Agents)" + signIn }
        if facts.hasNpx { return "Claude: the server’s own" + signIn }
        if !facts.canInstallClaude {
            return "Claude can’t be installed here: it uses \(facts.libc.display). Install it there yourself to use it."
        }
        if facts.downloader == nil { return "Claude can’t be installed here: it has neither curl nor wget." }
        return hasCredential && !host.ownSignInOnly
            ? "Claude: installed when \(host.label) next connects"
            : "Claude: installed the first time you start it here"
    }

    /// How many agents removing this server would stop, for the Remove dialog.
    func agentsLive(_ id: HostID) async -> Int {
        await connections[id]?.agentsLive() ?? 0
    }

    /// Remove a server: its agents stopped, its daemon gone, and with `purge` what
    /// Agents installed there; then forget it here. Its folders are left alone.
    func remove(_ id: HostID, purge: Bool = false) async {
        listening[id]?.cancel()
        retrying[id]?.cancel()
        if let connection = connections[id] {
            do { try await connection.remove(purge: purge) } catch { log("\(label(id)): remove: \(error)") }
        }
        connections[id] = nil
        states[id] = nil
        reachability.forget(id)
        hosts.remove(id)
        try? store.save(hosts)
    }

    // MARK: -

    /// `<root>/hosts/hosts.log`: every server's state as it changes, for finding out
    /// afterwards why one would not come back.
    private func log(_ line: String) {
        let file = locations.hostsFolder.appendingPathComponent("hosts.log")
        try? FileManager.default.createDirectory(at: locations.hostsFolder, withIntermediateDirectories: true)
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data(stamped.utf8)); try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: file)
        }
    }

    /// The ssh command for a host, its control socket under this root's `hosts/`.
    static func ssh(for host: ServerHost, locations: StoreLocations) -> SSHCommand {
        SSHCommand(executable: sshExecutable, name: host.sshName,
                   controlPath: locations.hostsFolder.appendingPathComponent("\(host.id.rawValue).ctl"))
    }

    static func connection(for host: ServerHost, locations: StoreLocations,
                           wantsClaude: @escaping @Sendable () async -> Bool,
                           offer: @escaping @Sendable () async -> DaemonAPI.CredentialsOffer? = { nil },
                           lender: DaemonClient.CredentialLender? = nil) -> ServerConnection {
        ServerConnection(hostID: host.id, ssh: ssh(for: host, locations: locations),
                         socket: locations.hostsFolder.appendingPathComponent("\(host.id.rawValue).sock"),
                         installedBy: ServerHost.currentMacName,
                         binary: { await ServerBinaries.binary(for: $0) },
                         toolset: { ServerBinaries.claudeToolset },
                         wantsClaude: wantsClaude, offer: offer, lender: lender)
    }

    /// A new connection for a host, asking this set what to offer and who lends (043).
    func newConnection(for host: ServerHost) -> ServerConnection {
        let id = host.id
        return Self.connection(for: host, locations: locations, wantsClaude: wantsClaude(id),
                               offer: { [weak self] in await MainActor.run { self?.offerFor(id) } },
                               lender: lenderFor(id))
    }

    /// Say again what this window may lend a server: a credential was just added (043).
    func offerCredentials(_ id: HostID) async {
        await connections[id]?.offerCredentials()
    }

    func lend(_ id: HostID, runtime: String, _ secret: Secret) async -> Bool {
        await connections[id]?.lend(runtime, secret) ?? false
    }

    /// For a connection made here or by the Add a server sheet: ask this set, on the main
    /// actor, at the moment the server connects.
    func wantsClaude(_ id: HostID) -> @Sendable () async -> Bool {
        { [weak self] in await MainActor.run { self?.claudeWanted(id) ?? false } }
    }

    private func makeConnection(_ host: ServerHost) -> ServerConnection {
        let connection = newConnection(for: host)
        follow(host.id, connection)
        return connection
    }

    private func follow(_ id: HostID, _ connection: ServerConnection) {
        Task {
            await connection.setOnState { [weak self] state in
                await self?.moved(id, to: state)
            }
            await connection.setOnClaude { [weak self] next in
                await self?.claudeMoved(id, to: next)
            }
            let now = await connection.claude
            claudeMoved(id, to: now)
        }
    }

    private func claudeMoved(_ id: HostID, to next: ServerConnection.Claude) {
        claude[id] = next
        // A newer toolset waits beside the old for the turns on it to end; look again in
        // half a minute, as 037 does for the daemon (FR-007).
        if case .updateWaiting = next {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, case .updateWaiting = self.claude[id] else { return }
                await self.installClaude(id)
            }
        }
        log("\(hosts[id]?.label ?? id.rawValue): claude \(next)")
        if case .ready(let toolset) = next, var host = hosts[id], host.facts?.toolsetID != toolset {
            host.facts?.toolsetID = toolset
            update(host)
        }
    }

    // MARK: A server that comes back empty (043 US3)

    /// What a connected server lists, against what it listed before: a folder it had and
    /// has no more is gone from it, and stays shown as gone until the person removes it.
    func noteProjects(_ id: HostID, listed: [DaemonAPI.ProjectSummary]) {
        guard var host = hosts[id] else { return }
        let paths = listed.map { $0.folder.path(percentEncoded: false) }
        let gone = host.knownProjects.filter { !paths.contains($0) }
        goneProjects[id] = gone
        let known = paths + gone
        if known != host.knownProjects {
            host.knownProjects = known
            update(host)
        }
    }

    func forgetGoneProject(_ id: HostID, path: String) {
        guard var host = hosts[id] else { return }
        host.knownProjects.removeAll { $0 == path }
        goneProjects[id]?.removeAll { $0 == path }
        update(host)
    }

    /// The person said the server was rebuilt: forget its old key, trust the one it has
    /// now, and set it up again as a new server (043, FR-017).
    func trustRebuilt(_ id: HostID, _ fetched: HostKeyCheck.Fetched) async throws {
        guard var host = hosts[id] else { return }
        let ssh = Self.ssh(for: host, locations: locations)
        let resolved = try await HostKeyCheck.resolve(ssh)
        try await HostKeyCheck.forget(resolved)
        try await HostKeyCheck.trust(fetched, into: resolved)
        host.trustedFingerprint = fetched.fingerprint
        update(host)
        log("\(host.label): rebuilt; new key \(fetched.fingerprint) trusted")
        connect(id)
    }

    /// Install Claude on a server now: chosen there for the first time, or Try again (043).
    func installClaude(_ id: HostID) async {
        await connections[id]?.installClaude()
    }

    private func moved(_ id: HostID, to state: ServerConnection.State) async {
        states[id] = state
        if case .failed(.hostKeyChanged) = state, rebuiltAsk == nil { rebuiltAsk = id }
        log("\(hosts[id]?.label ?? id.rawValue): \(state)")
        if let edge = reachability.moved(id, to: state), let host = hosts[id] {
            await onReachability?(host.label, edge == .cameBack)
        }
        switch state {
        case .connected:
            nextTry[id] = nil
            if let facts = await connections[id]?.facts, var host = hosts[id] {
                host.facts = facts
                update(host)
            }
            listen(id)
            await onConnected?(id)
        case .updateWaiting:
            // Talking to the old daemon until its turns end: listen to it, list it, and
            // try the swap again every half minute.
            listen(id)
            await onConnected?(id)
            retrying[id]?.cancel()
            retrying[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.connections[id]?.connect()
            }
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
            // The stream ends when the daemon's connection does. Unless this listener
            // was cancelled on purpose, that is the server's daemon gone.
            guard !Task.isCancelled else { return }
            await self?.connections[id]?.daemonWentAway()
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
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForQuit() }
        }
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

    /// Claude's pinned toolset, from `Resources/toolsets/claude` (043). Read once.
    nonisolated static let claudeToolset: Toolset? = {
        guard let folder = Bundle.main.url(forResource: "claude", withExtension: nil, subdirectory: "toolsets") else {
            return nil
        }
        return try? Toolset.load(from: folder)
    }()

    static var version: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(marketing)+\(build)"
    }
}
