import AgentsKitCore
import Foundation

/// Where the window's control plane is (058, US1, frame K): only ever elsewhere, reached
/// over a WebSocket with this window's own key, kept in the keychain on this Mac only
/// (#1031). No host is run from here and there is no old way: Agents Host does all of
/// that. This Mac's own host is also reached directly, over its socket in the app group
/// (#1118, `localLink`).
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
    /// A walk's own folder, where its walk socket is (#1172); nil for the person's window.
    static var walkFolder: URL? { walk == nil ? nil : folder }
    /// Not backed up (#1031): a restored Mac pairs again.
    private static var membershipFile: URL { folder.appendingPathComponent("control-client.json") }
    /// The window's key in the keychain; a walk's window has its own, as it has its own pairing.
    private static var keyAccount: String { walk.map { "control-client-key.walk.\($0)" } ?? "control-client-key" }

    static var endpoint: Endpoint? {
        _ = retiredFileKey
        guard let membership = ControlMembership.load(membershipFile), membership.client != nil, membership.url != nil else {
            return nil
        }
        return .remote(membership)
    }

    /// An older build kept the key in `control-client-key`, which went into backups
    /// (#1031). It goes, once, with the pairing made under it, so the window asks how to
    /// work again (v0.x, no migration).
    private static let retiredFileKey: Void = {
        let old = folder.appendingPathComponent("control-client-key")
        guard FileManager.default.fileExists(atPath: old.path) else { return }  // store-ok: the window's own container
        try? FileManager.default.removeItem(at: membershipFile)  // store-ok: the window's own container
        try? FileManager.default.removeItem(at: old)  // store-ok: the window's own container
    }()

    static var needsFirstRun: Bool { endpoint == nil }

    /// The apps' dial: `URLSession`, which works in the sandbox (S2).
    static let dial: ControlCodeUse.Dial = { url, pin in try await WebSocketLink.connect(url, pin: pin) }

    /// One connection for every host's client, to this window's control plane.
    static func link(_ endpoint: Endpoint) -> ControlLink? {
        switch endpoint {
        case .remote(let membership):
            guard let key = try? ControlClientKey.loadOrMake(account: keyAccount),
                  let dial = try? ControlCodeUse.clientDial(membership, privateKey: key, kind: "mac", dial: dial, keep: { newer in
                      // The control plane moved, or changed its certificate (R16): kept for next time,
                      // and tried again at the next answer if the disk refused it (#212).
                      try newer.save(membershipFile, backedUp: false)
                  }) else { return nil }
            return ControlLink(dial: dial)
        }
    }

    /// This Mac's host directly (#1118): agentsd's socket in the app group, named by the
    /// control plane's key, proved with this window's own key. Nil with no pairing, or no
    /// group container for this build.
    static func localLink(_ endpoint: Endpoint, host: MachineRef) -> LocalHostLink? {
        switch endpoint {
        case .remote(let membership):
            guard let client = membership.client,
                  let key = try? ControlClientKey.loadOrMake(account: keyAccount),
                  let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LocalHostLink.group)
            else { return nil }
            let socket = group.appendingPathComponent(LocalHostLink.socketName(controlKey: membership.controlKey))
            return LocalHostLink(socket: socket, client: client, privateKey: key, host: host)
        }
    }

    /// Forget This Mac (#344): the pairing goes, so the window asks how to work again, as
    /// at first run. Its key stays, as the Remote's does; a new pairing names it afresh.
    /// The control plane the organisation pins this Mac to, from the configuration profile
    /// in the window's own domain (#998, US7); read once.
    static let pin = MachinePin.managed()

    /// Why Forget This Mac is refused: the window is paired with the control plane its
    /// organisation pins (FR-027). Nil when it may go.
    static var leaveRefusal: String? {
        guard let pin, pin.namesAControlPlane, let membership = ControlMembership.load(membershipFile),
              pin.admits(membership) else { return nil }
        return pin.leaveRefusal
    }

    /// A code or a sign-in for another control plane than the pinned one is refused (FR-027).
    private static func refuseUnpinned(_ admitted: (MachinePin) -> Bool) throws {
        if let pin, pin.namesAControlPlane, !admitted(pin) { throw MachinePin.Refused(words: pin.refusal) }
    }

    static func forget() {
        try? FileManager.default.removeItem(at: membershipFile)  // store-ok: the window's own container
    }

    /// Connect to a control plane (frames C and K2): say who this window is with the code,
    /// then keep what it was told. What the window may do is the code's.
    static func pair(with code: ControlCode) async throws -> ControlMembership {
        try refuseUnpinned { $0.admits(code) }
        let key = try ControlClientKey.loadOrMake(account: keyAccount)
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key, id: UUID(),
                                                             name: Host.current().localizedName ?? "A Mac",
                                                             kind: .mac, dial: dial)
        // Given up on (Cancel, or the sheet's deadline): not kept, so the window does
        // not wake up paired with something the person walked away from (#84).
        try Task.checkCancellation()
        try membership.save(membershipFile, backedUp: false)
        return membership
    }

    /// Connect with no code, by signing in with Google, Apple or GitHub (#995): the window
    /// pairs as the person the sign-in names, and keeps what it was told, as `pair` does.
    static func signIn(at url: URL, with signIn: @escaping ControlSignIn.Provider,
                       waiting: @escaping @Sendable (DaemonAPI.SignInWaiting) -> Void) async throws -> ControlMembership {
        try refuseUnpinned { $0.admits(address: url.absoluteString) }
        let key = try ControlClientKey.loadOrMake(account: keyAccount)
        let membership = try await ControlSignIn.pair(url: url, pin: nil, controlKey: nil, privateKey: key, id: UUID(),
                                                      name: Host.current().localizedName ?? "A Mac", kind: .mac, dial: dial,
                                                      signIn: signIn, waiting: waiting)
        try Task.checkCancellation()
        try refuseUnpinned { $0.admits(membership) }
        try membership.save(membershipFile, backedUp: false)
        return membership
    }

    /// The control key this window trusts, which a sign-in's nonce is bound to (#995).
    static var controlKey: Data? {
        guard case .remote(let membership)? = endpoint else { return nil }
        return membership.controlKey
    }
}
