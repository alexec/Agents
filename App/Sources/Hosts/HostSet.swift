import AgentsKitCore
import Foundation
import Observation

/// The window's hosts (058, US1): only the control plane's. The window has no ssh of its
/// own, so this keeps the shape the views were written against when it did, with every
/// host named and judged online by what the control plane last said (`controlled`).
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

    /// What an action aimed at this Mac's host says when it is down (#83).
    static let macDownProblem = "This Mac’s host isn’t answering, so that didn’t happen. The window is trying again by itself; Try Again tries now."

    /// Why a button aimed at `id` does nothing now, in a tooltip's few words.
    func offlineHelp(_ id: HostID) -> String {
        id == .mac ? "This Mac’s host isn’t answering" : "\(label(id)) is offline"
    }

    func label(_ id: HostID) -> String {
        id == .mac ? "This Mac" : controlled[id]?.label ?? "a host"
    }

    func state(_ id: HostID) -> ServerConnection.State {
        guard id != .mac else { return macDownSince.map { .offline(since: $0) } ?? .connected }
        guard let controlled = controlled[id] else { return .idle }
        return controlled.online ? .connected : .offline(since: Date())
    }

    /// Since when this Mac's host has not answered the window, or nil while it does
    /// (#83). Servers are judged by what the control plane says; this Mac's host by the
    /// window's own connection to it, which AppModel keeps here so every view that
    /// greys out or holds back for an offline server does the same for this Mac.
    var macDownSince: Date?

    func isOffline(_ id: HostID) -> Bool {
        guard id != .mac else { return macDownSince != nil }
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

/// The states the window's own ssh connection to a server could be in, before 058. The
/// views still read them; the window never has one now.
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
