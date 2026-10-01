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
///
/// Away from anywhere that reaches the control plane's address, it goes through
/// `agents-relay` in the person's iCloud instead (T077), with the same key exchange end
/// to end inside, and back to the address as soon as it answers again.
enum RemoteControl {
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents", isDirectory: true)
    }
    private static var membershipFile: URL { folder.appendingPathComponent("control-client.json") }
    private static var keyFile: URL { folder.appendingPathComponent("control-client-key") }
    private static var relayKeyFile: URL { folder.appendingPathComponent("control-relay-key.pub") }
    /// Present when the membership came from a move (T085): the key is this device's own,
    /// the one it paired with the Mac under, not `control-client-key`. Kept for a device
    /// moved that way (FR-038); nothing tells a device of a move now the bridge is gone.
    private static var movedFile: URL { folder.appendingPathComponent("control-client-moved") }

    /// The relay's key, as the control plane named it in `control/status`, over a
    /// connection this device had already proved and checked the pin of. Without it
    /// nothing is written to iCloud.
    static var relayKey: Data? {
        guard let data = try? Data(contentsOf: relayKeyFile), data.count == 65 else { return nil }
        return data
    }

    static func keepRelayKey(_ key: Data?) {
        guard membership != nil, key != relayKey else { return }
        if let key {
            try? key.write(to: relayKeyFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            try? FileManager.default.removeItem(at: relayKeyFile)
        }
    }

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
        try? FileManager.default.removeItem(at: relayKeyFile)
        try? FileManager.default.removeItem(at: movedFile)
    }

    /// The link the Remote's model is built on while paired with a control plane.
    static func link() -> (any DaemonLink)? {
        guard let membership else { return nil }
        if FileManager.default.fileExists(atPath: movedFile.path) { return movedLink(membership) }
        guard let key = try? ControlAgreement.loadOrMake(file: keyFile),
              let dial = try? ControlCodeUse.clientDial(membership, privateKey: key, kind: kind.rawValue, dial: dial) else {
            return nil
        }
        let relayed: @Sendable () async throws -> any LineTransport = {
            guard let relayKey else { throw RelayTrouble.notPaired }
            return try await ControlCodeUse.relayedDial(membership, privateKey: key, relayKey: relayKey,
                                                        channel: CloudKitRelayChannel())()
        }
        return ControlPlaneLink(dial: dial, relayed: relayed)
    }
}

extension RemoteControl {
    /// A moved device's link: the same, with the key it paired with the Mac under.
    static func movedLink(_ membership: ControlMembership) -> (any DaemonLink)? {
        guard let client = membership.client,
              let key = try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup),
              let shared = try? key.controlClientKey(controlKey: membership.controlKey, client: client),
              let dial = try? ControlCodeUse.clientDial(membership, sharedKey: shared, kind: kind.rawValue, dial: dial) else {
            return nil
        }
        let relayed: @Sendable () async throws -> any LineTransport = {
            guard let relayKey else { throw RelayTrouble.notPaired }
            return try await ControlCodeUse.relayedDial(membership, sharedKey: shared, sealing: key, relayKey: relayKey,
                                                        channel: CloudKitRelayChannel())()
        }
        return ControlPlaneLink(dial: dial, relayed: relayed)
    }
}

/// A connection to the control plane as this device: its address first, then the relay
/// when the address cannot be reached (T077). Nothing to start when neither answers, only
/// the reconnect loop to try again.
struct ControlPlaneLink: DaemonLink {
    let dial: @Sendable () async throws -> any LineTransport
    var relayed: (@Sendable () async throws -> any LineTransport)?

    /// The same link without the relay: for a second connection, which the relay cannot
    /// carry beside the first.
    var addressOnly: ControlPlaneLink { ControlPlaneLink(dial: dial, relayed: nil) }

    /// How often a relayed connection looks for the address again.
    static let lookAgain: Duration = .seconds(30)

    func transport() async throws -> any LineTransport {
        do {
            return try await dial()
        } catch let refusal as ControlAuth.Refusal {
            // `DaemonClient` keeps only "could not connect"; the model asks what was said.
            // A control plane that answered and refused is not one to go round.
            ControlPlaneLink.refused.set(refusal.reason)
            throw refusal
        } catch {
            guard let relayed else { throw error }
            let transport: any LineTransport
            do {
                transport = try await relayed()
            } catch let refusal as ControlAuth.Refusal {
                ControlPlaneLink.refused.set(refusal.reason)
                throw refusal
            } catch RelayTrouble.notPaired {
                throw error
            }
            watchForTheAddress(while: transport)
            return transport
        }
    }

    /// While relayed, try the address now and then; when it answers, end the relayed
    /// connection so the model reconnects, and the address wins. One watcher, for the
    /// latest relayed connection.
    private func watchForTheAddress(while relayed: any LineTransport) {
        guard Self.watching.hold(relayed) else { return }
        let dial = self.dial
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.lookAgain)
                if let direct = try? await dial() {
                    direct.close()
                    Self.watching.take()?.close()
                    return
                }
            }
        }
    }

    static let watching = Watching()

    /// The relayed connection in use, and whether somebody is already watching for the
    /// address on its behalf.
    final class Watching: @unchecked Sendable {
        private let lock = NSLock()
        private var relayed: (any LineTransport)?
        /// Holds the connection; true when no watcher is running yet.
        func hold(_ transport: any LineTransport) -> Bool {
            lock.withLock {
                defer { relayed = transport }
                return relayed == nil
            }
        }
        func take() -> (any LineTransport)? { lock.withLock { defer { relayed = nil }; return relayed } }
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

/// The Remote before it has paired: nothing to dial, so it asks for a code.
struct NotPairedLink: DaemonLink {
    func transport() async throws -> any LineTransport { throw RelayTrouble.notPaired }
    func start() async throws {}
}
