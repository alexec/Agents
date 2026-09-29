#if AGENTS_STORE
import AgentsKitCore
import Foundation
import Observation

/// The App Store window's servers (058, US1): only the control plane's. The window has no
/// ssh of its own, so this keeps what `HostSet` keeps in the developer window, with the
/// server list always empty, and every other host named and judged online by what the
/// control plane last said (`controlled`). It goes, with `HostSet`, when the developer
/// window's own servers go (T106).
@MainActor
@Observable
final class HostSet {
    private(set) var hosts = HostList()
    private(set) var states: [HostID: ServerConnection.State] = [:]
    private(set) var nextTry: [HostID: Date] = [:]
    private(set) var goneProjects: [HostID: [String]] = [:]
    var rebuiltAsk: HostID?
    private(set) var claude: [HostID: ServerConnection.Claude] = [:]
    @ObservationIgnored var claudeWanted: (HostID) -> Bool = { _ in false }
    private(set) var toolsets: [HostID: [String: ServerConnection.Claude]] = [:]
    @ObservationIgnored var toolsetWanted: (HostID, String) -> Bool = { _, _ in false }
    @ObservationIgnored var offerFor: (HostID) -> DaemonAPI.CredentialsOffer? = { _ in nil }
    @ObservationIgnored var lenderFor: (HostID) -> DaemonClient.CredentialLender? = { _ in nil }
    @ObservationIgnored var onNotification: ((HostID, String, JSONValue?) async -> Void)?
    @ObservationIgnored var onConnected: ((HostID) async -> Void)?
    @ObservationIgnored var onReachability: ((String, Bool) async -> Void)?

    /// Hosts the control plane reaches for this window: their names, and whether each is
    /// online.
    var controlled: [HostID: (label: String, online: Bool)] = [:]
    var offlineSince: [HostID: Date] { [:] }

    init(locations: StoreLocations) {}

    func stopForQuit() {}
    func handOver() -> [HostID] { [] }
    var isEmpty: Bool { controlled.isEmpty }

    var servers: [HostID] {
        controlled.filter { $0.key != .mac }
            .sorted { $0.value.label.localizedStandardCompare($1.value.label) == .orderedAscending }.map(\.key)
    }

    func host(_ id: HostID) -> ServerHost? { nil }

    func label(_ id: HostID) -> String {
        id == .mac ? "This Mac" : controlled[id]?.label ?? "a host"
    }

    func state(_ id: HostID) -> ServerConnection.State {
        guard id != .mac else { return .connected }
        guard let controlled = controlled[id] else { return .idle }
        return controlled.online ? .connected : .offline(since: Date())
    }

    func isOffline(_ id: HostID) -> Bool {
        guard id != .mac else { return false }
        if case .connected = state(id) { return false }
        return true
    }

    func client(for id: HostID) -> DaemonClient? { nil }
    func start() {}
    func connect(_ id: HostID) {}
    func retryNow() {}
    func update(_ host: ServerHost) {}
    func setOwnSignInOnly(_ id: HostID, _ on: Bool) {}
    func claudeLine(_ id: HostID, canRelay: Bool) -> String { "" }
    func toolsetLine(_ id: HostID, runtimeID: String, hasCredential: Bool) -> String { "" }
    func agentsLive(_ id: HostID) async -> Int { 0 }
    func remove(_ id: HostID, purge: Bool = false) async {}
    func noteProjects(_ id: HostID, listed: [DaemonAPI.ProjectSummary]) {}
    func forgetGoneProject(_ id: HostID, path: String) {}
    func installClaude(_ id: HostID) async {}
}

/// The states a developer window's ssh connection to a server can be in, named here so
/// the views shared with it compile. The App Store window never has one.
enum ServerConnection {
    enum State: Sendable, Equatable {
        case idle
        case connecting(Step)
        case connected
        case offline(since: Date)
        case failed(HostProblem)
        case updateWaiting
    }

    enum Step: String, Sendable, Equatable {
        case connect, checkSystem, setUp, installClaude, findRuntimes
    }

    enum Claude: Sendable, Equatable {
        case unknown
        case notInstalled
        case installing
        case ready(String)
        case own
        case failed(HostProblem)
        case updateWaiting
    }
}
#endif
