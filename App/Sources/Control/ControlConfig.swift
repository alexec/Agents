import AgentsKitCore
import Foundation

/// Where the window's control plane is (058, US1, frame K): only ever elsewhere, reached
/// over a WebSocket with this window's own key, kept in its container. There is no local
/// socket, no host run from here and no old way: Agents Host does all of that.
enum ControlConfig {
    enum Endpoint {
        case remote(ControlMembership)
    }

    /// The window's own container, whatever `AGENTS_ROOT` says: a sandboxed window never
    /// keeps anything in a daemon's root, and a walk launched from a shell carries one.
    /// A walk's window (`--walk <name>`, run-app) keeps its pairing in a folder of its own
    /// there, so it never takes the person's window's, which shares the container.
    private static var folder: URL {
        let own = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents", isDirectory: true)
        guard let walk else { return own }
        return own.appendingPathComponent("walks", isDirectory: true).appendingPathComponent(walk, isDirectory: true)
    }

    static let walkArgument = "--walk"
    /// `--walk <name>`: a letter, digit, `-` or `_` name, so it cannot step out of `walks/`.
    static let walk: String? = {
        let arguments = CommandLine.arguments
        guard let at = arguments.firstIndex(of: walkArgument), arguments.indices.contains(at + 1) else { return nil }
        let name = arguments[at + 1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return name
    }()
    /// Where a walk's window writes the page Open in Browser would open (#109), for the
    /// walk's headless browser to go to: a walk never opens the person's own browser.
    static var walkOpenedURL: URL? { walk == nil ? nil : folder.appendingPathComponent("opened-url") }
    private static var membershipFile: URL { folder.appendingPathComponent("control-client.json") }
    private static var keyFile: URL { folder.appendingPathComponent("control-client-key") }

    static var endpoint: Endpoint? {
        guard let membership = ControlMembership.load(membershipFile), membership.client != nil, membership.url != nil else {
            return nil
        }
        return .remote(membership)
    }

    static var needsFirstRun: Bool { endpoint == nil }

    /// The apps' dial: `URLSession`, which works in the sandbox (S2).
    static let dial: ControlCodeUse.Dial = { url, pin in try await WebSocketLink.connect(url, pin: pin) }

    /// One connection for every host's client, to this window's control plane.
    static func link(_ endpoint: Endpoint) -> ControlLink? {
        switch endpoint {
        case .remote(let membership):
            guard let key = try? ControlAgreement.loadOrMake(file: keyFile),
                  let dial = try? ControlCodeUse.clientDial(membership, privateKey: key, kind: "mac", dial: dial, keep: { newer in
                      // The control plane moved, or changed its certificate (R16): kept for next time,
                      // and tried again at the next answer if the disk refused it (#212).
                      try newer.save(membershipFile)
                  }) else { return nil }
            return ControlLink(dial: dial)
        }
    }

    static func macClient() -> DaemonClient {
        guard let endpoint, let link = link(endpoint) else { return DaemonClient(link: UnreachableLink()) }
        return DaemonClient(link: link.link(for: .mac))
    }

    /// Forget This Mac (#344): the pairing goes, so the window asks how to work again, as
    /// at first run. Its key stays, as the Remote's does; a new pairing names it afresh.
    static func forget() {
        try? FileManager.default.removeItem(at: membershipFile)  // store-ok: the window's own container
    }

    /// Connect to a control plane (frames C and K2): say who this window is with the code,
    /// then keep what it was told. What the window may do is the code's.
    static func pair(with code: ControlCode) async throws -> ControlMembership {
        let key = try ControlAgreement.loadOrMake(file: keyFile)
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key, id: UUID(),
                                                             name: Host.current().localizedName ?? "A Mac",
                                                             kind: .mac, dial: dial)
        // Given up on (Cancel, or the sheet's deadline): not kept, so the window does
        // not wake up paired with something the person walked away from (#84).
        try Task.checkCancellation()
        try membership.save(membershipFile)
        return membership
    }
}
