import AgentsKitCore
import Foundation
import UIKit

/// The Remote as a client of a control plane (058, US5, T076): paired with a version 2
/// device code, then dialling the control plane's one address over a WebSocket, with the
/// pin from the code and a key of this device's own.
///
/// What the phone says on this connection goes to the control plane's home host, as it
/// did to the Mac; `RemoteModel` reaches every other host over a second connection
/// wrapped by `ControlLink`. The first build's TLS link to a Mac's bridge (`AwayLink`)
/// stays only for a Mac that has not moved yet (until T112).
enum RemoteControl {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents", isDirectory: true)
    }
    private static var membershipFile: URL { folder.appendingPathComponent("control-client.json") }
    private static var keyFile: URL { folder.appendingPathComponent("control-client-key") }

    /// This device's pairing with a control plane, if it has one.
    static var membership: ControlMembership? {
        guard let kept = ControlMembership.load(membershipFile), kept.client != nil, kept.url != nil else { return nil }
        return kept
    }

    static var kind: ClientRecord.Kind { UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone }

    /// The phone's dial: `URLSession`'s WebSocket, which checks the pin.
    static let dial: ControlCodeUse.Dial = { url, pin in try await WebSocketLink.connect(url, pin: pin) }

    /// Pair with a device code: say who this is, once, and keep what the control plane said.
    @discardableResult
    static func pair(with code: ControlCode, id: UUID) async throws -> ControlMembership {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = try ControlAgreement.loadOrMake(file: keyFile)
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key, id: id,
                                                             name: UIDevice.current.name, kind: kind, dial: dial)
        try membership.save(membershipFile)
        return membership
    }

    /// Forget the pairing: this device goes back to asking for a code.
    static func forget() {
        try? FileManager.default.removeItem(at: membershipFile)
    }

    /// The link the Remote's model is built on while paired with a control plane.
    static func link() -> (any DaemonLink)? {
        guard let membership, let key = try? ControlAgreement.loadOrMake(file: keyFile),
              let dial = try? ControlCodeUse.clientDial(membership, privateKey: key, kind: kind.rawValue, dial: dial) else {
            return nil
        }
        return ControlPlaneLink(dial: dial)
    }
}

/// A connection to the control plane as this device: nothing to start when it doesn't
/// answer, only the reconnect loop to try again.
struct ControlPlaneLink: DaemonLink {
    let dial: @Sendable () async throws -> any LineTransport
    func transport() async throws -> any LineTransport {
        do {
            return try await dial()
        } catch let refusal as ControlAuth.Refusal {
            // `DaemonClient` keeps only "could not connect"; the model asks what was said.
            ControlPlaneLink.refused.set(refusal.reason)
            throw refusal
        }
    }
    func start() async throws {}

    /// The last refusal the control plane gave this device, taken once.
    static let refused = Refused()

    final class Refused: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: ControlAuth.Reason?
        func set(_ reason: ControlAuth.Reason) { lock.withLock { self.reason = reason } }
        func take() -> ControlAuth.Reason? { lock.withLock { defer { reason = nil }; return reason } }
    }
}
