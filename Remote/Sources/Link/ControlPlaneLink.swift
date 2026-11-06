import AgentsKitCore
import Foundation
import UIKit

/// The Remote as a client of a control plane (058, US5, T076): paired with a version 2
/// device code, then dialling the control plane's one address over a WebSocket, with the
/// pin from the code and a key of this device's own.
///
/// What the phone says on this connection goes to the control plane's home host, as it
/// did to the Mac; `RemoteModel` reaches every other host over a second connection
/// wrapped by `ControlLink`. The first build's TLS link to a Mac's bridge went in T106.
/// The relay through iCloud went in #3390: the control plane's address is the only way.
enum RemoteControl {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents", isDirectory: true)
    }
    /// Not backed up (#1031): a restored device pairs again. Its key is in the keychain,
    /// this device only (`ControlClientKey`).
    private static var membershipFile: URL { folder.appendingPathComponent("control-client.json") }
    /// Present when the membership came from a move (T085): the key is this device's own,
    /// the one it paired with the Mac under, not `ControlClientKey`. Kept for a device
    /// moved that way (FR-038); nothing tells a device of a move now the bridge is gone.
    private static var movedFile: URL { folder.appendingPathComponent("control-client-moved") }

    /// This device's pairing with a control plane, if it has one.
    static var membership: ControlMembership? {
        _ = retiredFileKey
        guard let kept = ControlMembership.load(membershipFile), kept.client != nil, kept.url != nil else { return nil }
        return kept
    }

    static var kind: ClientRecord.Kind { UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone }

    /// Where this device keeps the head of the machine lock it last checked (#3490): one for
    /// each control plane.
    static var lockPinName: String {
        guard let membership else { return "machineLockPin" }
        return "machineLockPin." + membership.controlKey.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The phone's dial: `URLSession`'s WebSocket, which checks the pin, given as long as
    /// the link allows the address (#884).
    static let dial: ControlCodeUse.Dial = { url, pin in
        try await WebSocketLink.connect(url, pin: pin, timeout: ControlPlaneLink.patience)
    }

    /// Pair with a device code: say who this is, once, and keep what the control plane said.
    @discardableResult
    static func pair(with code: ControlCode, id: UUID) async throws -> ControlMembership {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = try ControlClientKey.loadOrMake()
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key, id: id,
                                                             name: UIDevice.current.name, kind: kind, dial: dial)
        // Given up on before it answered (#84): not kept.
        try Task.checkCancellation()
        try membership.save(membershipFile, backedUp: false)
        return membership
    }

    /// Pair with no code, by signing in with Google, Apple or GitHub (#995): kept as `pair` keeps it.
    @discardableResult
    static func signIn(at url: URL, id: UUID, with signIn: @escaping ControlSignIn.Provider,
                       waiting: @escaping @Sendable (DaemonAPI.SignInWaiting) -> Void) async throws -> ControlMembership {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = try ControlClientKey.loadOrMake()
        let membership = try await ControlSignIn.pair(url: url, pin: nil, controlKey: nil, privateKey: key, id: id,
                                                      name: UIDevice.current.name, kind: kind, dial: dial, signIn: signIn,
                                                      waiting: waiting)
        try Task.checkCancellation()
        try membership.save(membershipFile, backedUp: false)
        return membership
    }

    /// The control key this device trusts, which a sign-in's nonce is bound to (#995).
    static var controlKey: Data? { membership?.controlKey }

    /// An older build kept the key in `control-client-key`, which went into backups
    /// (#1031). It goes, once, with the pairing made under it, so the device asks for a
    /// code again (v0.x, no migration); a moved device's pairing never used it.
    private static let retiredFileKey: Void = {
        let old = folder.appendingPathComponent("control-client-key")
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        if !FileManager.default.fileExists(atPath: movedFile.path) {
            try? FileManager.default.removeItem(at: membershipFile)
        }
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("control-relay-key.pub"))
    }()

    /// Forget the pairing: this device goes back to asking for a code.
    static func forget() {
        try? FileManager.default.removeItem(at: membershipFile)
        try? FileManager.default.removeItem(at: movedFile)
    }

    /// A newer list of the control plane's endpoints, given when it moved or changed its
    /// certificate (R16): kept, so the next launch dials there. One the disk refused is tried
    /// again at the next answer (#212).
    static let keepNewer: EndpointBook.Keep = { newer in try newer.save(membershipFile, backedUp: false) }

    /// The link the Remote's model is built on while paired with a control plane.
    static func link() -> (any DaemonLink)? {
        guard let membership else { return nil }
        if FileManager.default.fileExists(atPath: movedFile.path) { return movedLink(membership) }
        guard let key = try? ControlClientKey.loadOrMake(),
              let dial = try? ControlCodeUse.clientDial(membership, privateKey: key, kind: kind.rawValue, dial: dial,
                                                        keep: keepNewer) else {
            return nil
        }
        return ControlPlaneLink(dial: dial)
    }
}

extension RemoteControl {
    /// This device's key and client id as the control plane knows them, to open what was
    /// sealed to it and seal it again (#3397); nil when not paired.
    static func sealing() -> (key: DeviceKey, client: UUID)? {
        guard let membership, let client = membership.client else { return nil }
        if FileManager.default.fileExists(atPath: movedFile.path) {
            return (try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup)).map { ($0, client) }
        }
        guard let raw = try? ControlClientKey.loadOrMake(), let key = try? DeviceKey.software(privateKey: raw) else { return nil }
        return (key, client)
    }

    /// A moved device's link: the same, with the key it paired with the Mac under.
    static func movedLink(_ membership: ControlMembership) -> (any DaemonLink)? {
        guard let client = membership.client,
              let key = try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup),
              let dial = try? ControlCodeUse.clientDial(membership,
                                                        sharedKey: { try key.controlClientKey(controlKey: $0, client: client) },
                                                        kind: kind.rawValue, dial: dial, keep: keepNewer) else {
            return nil
        }
        return ControlPlaneLink(dial: dial)
    }
}

/// The Remote before it has paired: nothing to dial, so it asks for a code.
struct NotPairedLink: DaemonLink {
    struct NotPaired: Error {}
    func transport() async throws -> any LineTransport { throw NotPaired() }
    func start() async throws {}
}
