#if !AGENTS_STORE
import AgentsKit
import AgentsKitCore
import Foundation
import ServiceManagement

/// Where this window's control plane is, when it has one (058).
///
/// With one, the window starts nothing: it reaches this Mac's host through the control
/// plane, and the host is kept running by something else. Without one it is the window it
/// always was, which spawns `agentsd` and talks to its socket, until the set-up is moved
/// across (R7, "Transition").
///
/// Two kinds. A control plane on this Mac is reached through its local socket, and is
/// said with `--control-root <path>` or `AGENTS_CONTROL_ROOT`, or saved by Run one on this
/// Mac. One elsewhere is reached over the network with this window's own key, saved by
/// Connect to a control plane beside this window's root. Saved under keys with the
/// window's root in them: a scratch copy shares the real app's defaults.
enum ControlConfig {
    enum Endpoint {
        case local(URL)
        case remote(ControlMembership)
    }

    private static var savedKey: String { "controlRoot:" + StoreLocations.default.root.standardizedFileURL.path }
    private static var membershipFile: URL { StoreLocations.default.root.appendingPathComponent("control-client.json") }
    private static var keyFile: URL { StoreLocations.default.root.appendingPathComponent("control-client-key") }

    static var endpoint: Endpoint? {
        if let root { return .local(root) }
        if let membership = ControlMembership.load(membershipFile), membership.client != nil { return .remote(membership) }
        return nil
    }

    /// The control root on this Mac, if this window's control plane is here.
    static var root: URL? {
        ControlPlane.chosenRoot() ?? UserDefaults.standard.string(forKey: savedKey).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static func save(_ root: URL) {
        UserDefaults.standard.set(root.path, forKey: savedKey)
    }

    /// Whether the window should ask how to work (FR-017): no control plane, and nothing
    /// of the old way to keep using. A root with agents or projects on it goes on the old
    /// way until it is moved across (US6).
    static var needsFirstRun: Bool {
        guard endpoint == nil else { return false }
        // Its agents run for a control plane elsewhere, and this window isn't paired.
        if hostOnly != nil { return true }
        let locations = StoreLocations.default
        let files = FileManager.default
        if files.fileExists(atPath: locations.projects.path) || files.fileExists(atPath: locations.socket.path) {
            return false
        }
        let agents = (try? files.contentsOfDirectory(atPath: locations.agents.path)) ?? []
        return agents.isEmpty
    }

    /// This Mac as only a host of a control plane elsewhere (058, US7): what enrolling
    /// kept in the root, for the daemon to dial out with.
    static var hostOnly: ControlMembership? {
        guard root == nil else { return nil }
        return ControlMembership.load(StoreLocations.default.controlHostMembership)
    }

    /// Run a Host Here: enrol this Mac's host with a host code, keep the membership in
    /// the root, then let launchd run the daemon that dials out with it. The code is
    /// used here, once, and never written down.
    static func runHostHere(with code: ControlCode, services: LocalServices) async throws -> ControlMembership {
        let locations = StoreLocations.default
        let key = try DeviceKey.load(file: locations.controlHostKey)
        let membership = try await ControlDialling.enroll(code, announce: DaemonAPI.HostAnnounce(
            publicKey: key.publicKey, name: services.hostName, platform: Daemon.platform,
            version: Daemon.version, machineID: services.machineID))
        try membership.save(locations.controlHostMembership)
        switch await services.registerHostOnly() {
        case .enabled: return membership
        case .needsApproval:
            SMAppService.openSystemSettingsLoginItems()
            throw HostOnlyFailure(description: "Allow Agents in System Settings ▸ Login Items, then press Run a Host Here again.")
        case .failed(let why): throw HostOnlyFailure(description: why)
        }
    }

    struct HostOnlyFailure: Error, CustomStringConvertible { let description: String }

    /// One connection for every host's client, to a control plane on this Mac.
    static func link(root: URL) -> ControlLink {
        let socket = ControlPlane.clientSocket(root: root).path
        return ControlLink { FDTransport(socket: try connectUnixSocket(path: socket)) }
    }

    /// One connection for every host's client, to wherever this window's control plane is.
    static func link(_ endpoint: Endpoint) -> ControlLink? {
        switch endpoint {
        case .local(let root):
            return link(root: root)
        case .remote(let membership):
            guard let key = try? DeviceKey.load(file: keyFile) else { return nil }
            return ControlLink(dial: ControlDialling.clientDial(membership, key: key))
        }
    }

    /// The client for this Mac's own host: through the control plane when there is one.
    static func macClient() -> DaemonClient {
        guard let endpoint, let link = link(endpoint) else { return DaemonClient() }
        return DaemonClient(link: link.link(for: .mac))
    }

    /// Connect to a control plane (frame C, T029): say who this window is with the code,
    /// then keep what it was told. What the window may do is the code's.
    static func pair(with code: ControlCode) async throws -> ControlMembership {
        let key = try DeviceKey.load(file: keyFile)
        let membership = try await ControlDialling.pair(code, key: key, id: UUID(),
                                                        name: Host.current().localizedName ?? "A Mac", kind: .mac)
        try membership.save(membershipFile)
        return membership
    }
}
#endif
