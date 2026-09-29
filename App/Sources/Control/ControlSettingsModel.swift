#if !AGENTS_STORE
import AgentsKit
#endif
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

    /// Where the control plane is, as the page says it when it can't be reached: its
    /// folder on this Mac, or the addresses it was paired at.
    let whereItIs: String
    private let link: ControlLink
    private let client: DaemonClient
    private var listening: Task<Void, Never>?

    init?(endpoint: ControlConfig.Endpoint) {
        guard let link = ControlConfig.link(endpoint) else { return nil }
        self.link = link
        client = DaemonClient(link: link.controlLink)
        switch endpoint {
        #if !AGENTS_STORE
        case .local(let root): whereItIs = SharedFiles.tilde(root.path)
        #endif
        case .remote(let membership):
            whereItIs = "\(membership.name) (\(membership.url ?? membership.addresses.first ?? "no address"))"
        }
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
                    if note.method == DaemonAPI.Notification.controlInstallProgress {
                        self.installStep = note.params?["step"]?.stringValue
                        continue
                    }
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

    /// The step the control plane says an install is at (`control/installProgress`).
    private(set) var installStep: String?

    enum InstallOutcome: Equatable {
        case added(name: String)
        /// The server's key is new to this Mac: the person looks at it and says so.
        case needsTrust(fingerprint: String)
        case failed(String)
    }

    /// Add a server: the control plane installs it over ssh and makes it a host (US3).
    func install(destination: String, trust: String? = nil) async -> InstallOutcome {
        installStep = nil
        var params: [String: JSONValue] = ["destination": .string(destination)]
        if let trust { params["trust"] = .string(trust) }
        do {
            let answer = try await client.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
            await refresh()
            if let fingerprint = answer["needsTrust"]?.stringValue { return .needsTrust(fingerprint: fingerprint) }
            return .added(name: answer["name"]?.stringValue ?? destination)
        } catch let error as JSONRPCError {
            return .failed(error.message)
        } catch {
            return .failed("The control plane can’t be reached.")
        }
    }

    /// A code for a new client with `grant`, or for a new host (frame G, Add by Code).
    func startCode(forHost: Bool, grant: Grant = .operator) async -> DaemonAPI.ControlCodeShown? {
        do {
            let shown: DaemonAPI.ControlCodeShown = if forHost {
                try await client.call(DaemonAPI.Method.hostsStartEnroll, returning: DaemonAPI.ControlCodeShown.self)
            } else {
                try await client.call(DaemonAPI.Method.clientsStartPairing, ["grant": JSONValue.string(grant.rawValue)],
                                      returning: DaemonAPI.ControlCodeShown.self)
            }
            problem = nil
            return shown
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = "The control plane can’t be reached."
        }
        return nil
    }

    func stopCodes() async {
        _ = try? await client.call(DaemonAPI.Method.clientsStopPairing)
    }

    func restart() async {
        #if AGENTS_STORE
        // The control plane on this Mac is Agents Host's to restart.
        problem = "Restart the control plane from Agents Host."
        return
        #else
        guard await LocalServices.forThisWindow.restartControlPlane() else {
            problem = "The control plane on this Mac could not be restarted."
            return
        }
        isReachable = false
        #endif
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
