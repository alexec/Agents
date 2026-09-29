#if AGENTS_STORE
import AgentsKitCore
import Foundation

/// Where the App Store window's control plane is (058, US1, frame K): only ever elsewhere,
/// reached over a WebSocket with this window's own key, kept in its container. There is
/// no local socket, no host run from here and no old way: Agents Host does all of that.
enum ControlConfig {
    enum Endpoint {
        case remote(ControlMembership)
    }

    private static var folder: URL { StoreLocations.default.root }
    private static var membershipFile: URL { folder.appendingPathComponent("control-client.json") }
    private static var keyFile: URL { folder.appendingPathComponent("control-client-key") }

    static var endpoint: Endpoint? {
        guard let membership = ControlMembership.load(membershipFile), membership.client != nil, membership.url != nil else {
            return nil
        }
        return .remote(membership)
    }

    /// Never on this Mac's disk: the window reads nothing of a control plane's.
    static var root: URL? { nil }
    static func save(_ root: URL) {}
    static var needsFirstRun: Bool { endpoint == nil }
    static var hostOnly: ControlMembership? { nil }

    /// The apps' dial: `URLSession`, which works in the sandbox (S2).
    static let dial: ControlCodeUse.Dial = { url, pin in try await WebSocketLink.connect(url, pin: pin) }

    /// One connection for every host's client, to this window's control plane.
    static func link(_ endpoint: Endpoint) -> ControlLink? {
        switch endpoint {
        case .remote(let membership):
            guard let key = try? ControlAgreement.loadOrMake(file: keyFile),
                  let dial = try? ControlCodeUse.clientDial(membership, privateKey: key, kind: "mac", dial: dial) else { return nil }
            return ControlLink(dial: dial)
        }
    }

    static func macClient() -> DaemonClient {
        guard let endpoint, let link = link(endpoint) else { return DaemonClient(link: UnreachableLink()) }
        return DaemonClient(link: link.link(for: .mac))
    }

    /// Connect to a control plane (frames C and K2): say who this window is with the code,
    /// then keep what it was told. What the window may do is the code's.
    static func pair(with code: ControlCode) async throws -> ControlMembership {
        let key = try ControlAgreement.loadOrMake(file: keyFile)
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key, id: UUID(),
                                                             name: Host.current().localizedName ?? "A Mac",
                                                             kind: .mac, dial: dial)
        try membership.save(membershipFile)
        return membership
    }
}
#endif
