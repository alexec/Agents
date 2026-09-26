import AgentsKit
import AgentsKitCore
import Foundation

/// What Settings ▸ Control plane shows (058, frames D–F): the control plane itself, its
/// hosts and its clients, kept true by the control plane's own notifications.
///
/// A connection of its own to the control plane, as the window's second client session:
/// Settings can be open while the window reconnects, and the other way round.
@MainActor
@Observable
final class ControlSettingsModel {
    private(set) var status: DaemonAPI.ControlStatus?
    private(set) var hosts: [DaemonAPI.ControlHost] = []
    private(set) var clients: [ClientRecord] = []
    /// Said when an action was refused, in the words the control plane used.
    var problem: String?
    private(set) var isReachable = false

    let root: URL
    private let link: ControlLink
    private let client: DaemonClient
    private var listening: Task<Void, Never>?

    init(root: URL) {
        self.root = root
        link = ControlConfig.link(root: root)
        client = DaemonClient(link: link.controlLink)
    }

    /// Whether the control plane runs on this Mac, and so may be restarted from here.
    var isOnThisMac: Bool { status?.machineID == MachineID.current }

    /// The host on this Mac: shown first and without buttons (the look gate's decision).
    var thisMacHost: DaemonAPI.ControlHost? { hosts.first { $0.machineID == MachineID.current } }
    var otherHosts: [DaemonAPI.ControlHost] { hosts.filter { $0.machineID != MachineID.current } }

    var onlineCount: Int { hosts.filter { $0.state == "online" }.count }
    var operatorCount: Int { clients.filter { $0.grant == .operator }.count }

    func start() async {
        await refresh()
        guard listening == nil else { return }
        listening = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for await note in self.client.notifications() where note.method.hasPrefix("control/") {
                    await self.refresh()
                }
                // The control plane went; come back when it does.
                self.isReachable = false
                try? await Task.sleep(for: .seconds(2))
                await self.refresh()
            }
        }
    }

    func stop() {
        listening?.cancel()
        listening = nil
        Task { await client.disconnect() }
    }

    func refresh() async {
        do {
            try await client.connect(startIfNeeded: false, timeout: .seconds(2))
            status = try await client.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
            hosts = try await client.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
            clients = try await client.call(DaemonAPI.Method.clientsList, returning: [ClientRecord].self)
                .sorted { ($0.id == status?.you ? 0 : 1, $0.paired) < ($1.id == status?.you ? 0 : 1, $1.paired) }
            isReachable = true
        } catch {
            isReachable = false
        }
    }

    // MARK: Actions

    func setGrant(_ grant: Grant, of client: UUID) async {
        await perform(DaemonAPI.Method.clientsSetGrant, DaemonAPI.ClientGrantRequest(client: client, grant: grant))
    }

    func forget(_ client: UUID) async {
        await perform(DaemonAPI.Method.clientsForget, DaemonAPI.ClientRequest(client: client))
    }

    func checkAgain(_ host: HostID) async {
        await perform(DaemonAPI.Method.hostsCheckAgain, DaemonAPI.HostRequest(host: host))
    }

    func remove(_ host: HostID) async {
        await perform(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host))
    }

    func restart() async {
        guard await LocalServices.forThisWindow.restartControlPlane() else {
            problem = "The control plane on this Mac could not be restarted."
            return
        }
        isReachable = false
    }

    private func perform(_ method: String, _ params: some Encodable & Sendable) async {
        do {
            _ = try await client.call(method, params)
            problem = nil
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = "The control plane can’t be reached."
        }
        await refresh()
    }
}
