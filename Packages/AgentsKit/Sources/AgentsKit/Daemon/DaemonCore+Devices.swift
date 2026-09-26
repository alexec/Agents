import AgentsKitCore
import Foundation

/// Pairing (021 US5): who may be told, and (046) who may reach this Mac from away.
///
/// A device pairs by scanning the code the Mac shows (security review, Phase 3; this
/// replaces 046's D1, where announcing on the home network was enough). The code holds
/// the Mac's key and a one-time secret; the bridge takes the secret as a TLS key, and
/// only a connection locked with it may announce a device the Mac has not seen. A
/// paired device announces again over its own link, which only updates its record.
/// A lost device is forgotten (FR-008), which ends both links, and pairs again by
/// scanning again.
extension DaemonCore {
    /// Every record, read from disk the first time it is wanted.
    var devices: [UUID: Device] {
        if let loadedDevices { return loadedDevices }
        let loaded = Dictionary(deviceStore.load().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loadedDevices = loaded
        return loaded
    }

    func device(_ id: UUID) -> Device? { devices[id] }

    /// The devices the ladder may see: every one that has announced.
    var pairedDevices: [Device] { Array(devices.values) }

    func saveDevice(_ device: Device) throws {
        var all = devices
        all[device.id] = device
        loadedDevices = all
        try deviceStore.save(Array(all.values))
        broadcast(DaemonAPI.Notification.deviceChanged, DaemonAPI.DeviceNotification(device))
    }

    /// `devices/list`, announced first.
    func allDevices() -> [Device] {
        devices.values.sorted { $0.announcedAt < $1.announcedAt }
    }

    /// `devices/announce`. The same id with the same key is the same device and gets
    /// its record back. The same id with a **different** key is refused: a key never
    /// changes under an identity, and a device that wants a new key is a new device
    /// with a new id.
    ///
    /// A device not yet on record is taken only from a connection locked with the pairing
    /// code the Mac is showing, and that code is then spent. The Mac's own window may
    /// still record one, as it always could; a device's connection never.
    func announce(_ announcement: DaemonAPI.DeviceAnnouncement, role: ConnectionRole = .control) throws -> Device {
        if role == .pairing {
            guard let code = pendingPairing, code.expires > now() else {
                throw JSONRPCError(code: DaemonAPI.Failure.notAllowed,
                                   message: "That pairing code has run out. Show a new one on the Mac.")
            }
        }
        if device(announcement.id) == nil, role == .device {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed,
                               message: "Pair this device by scanning the code in the Mac's Settings.")
        }
        defer { if role == .pairing { endPairing() } }
        if let existing = device(announcement.id) {
            guard existing.publicKey == announcement.publicKey else {
                throw JSONRPCError(code: DaemonAPI.Failure.notSupported,
                                   message: "A device's key does not change. A device with a new key is a new device.")
            }
            var known = existing
            known.name = announcement.name
            known.kind = announcement.kind
            known.lastSeenAt = now()
            try saveDevice(known)
            return known
        }
        let now = now()
        let made = Device(id: announcement.id, publicKey: announcement.publicKey,
                          name: announcement.name, kind: announcement.kind,
                          announcedAt: now, lastSeenAt: now)
        try saveDevice(made)
        reconsider()
        return made
    }

    /// `devices/forget` (046). The Mac's window only: a phone cannot forget itself or
    /// another phone. Forgetting a device that is not on record is already done.
    func forgetDevice(_ id: UUID, from surface: Surface?) throws {
        if surface?.deviceID != nil {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed,
                               message: "Only the Mac can forget a device.")
        }
        guard devices[id] != nil else { return }
        var all = devices
        all.removeValue(forKey: id)
        loadedDevices = all
        try deviceStore.save(Array(all.values))
        broadcast(DaemonAPI.Notification.deviceChanged, DaemonAPI.DeviceNotification(removed: id))
        reconsider()
    }

    // MARK: Pairing codes

    /// `devices/startPairing`. A fresh code each time, replacing any before it, so two
    /// sheets opened one after the other leave only the second's code working.
    func startPairing() throws -> DaemonAPI.PairingCode {
        guard let macKey = relayKey() else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed,
                               message: "The phone bridge isn't running, so there is nothing for a phone to pair with.")
        }
        // The system's generator: arc4random on the Mac, getrandom on Linux, both made
        // for secrets.
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let code = DaemonAPI.PairingCode(macKey: macKey, secret: secret, name: Self.macName,
                                         expires: now().addingTimeInterval(Self.pairingLifetime))
        pendingPairing = code
        broadcast(DaemonAPI.Notification.pairingChanged, JSONValue.object([:]))
        return code
    }

    /// `devices/stopPairing`.
    func stopPairing() {
        endPairing()
    }

    /// `pairing/current`, for the bridge. An expired code is not handed out.
    func currentPairing() -> DaemonAPI.PairingSecret {
        guard let code = pendingPairing, code.expires > now() else { return DaemonAPI.PairingSecret(secret: nil, expires: nil) }
        return DaemonAPI.PairingSecret(secret: code.secret, expires: code.expires)
    }

    func endPairing() {
        guard pendingPairing != nil else { return }
        pendingPairing = nil
        broadcast(DaemonAPI.Notification.pairingChanged, JSONValue.object([:]))
    }

    /// Five minutes: long enough to find the phone and open the app, short enough that a
    /// code left on the screen is soon worth nothing.
    static let pairingLifetime: TimeInterval = 5 * 60

    /// What the bridge advertises itself as, so the phone looks for this Mac by name.
    static var macName: String {
        #if os(macOS)
        Host.current().localizedName ?? "This Mac"
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    /// The public half of the Mac's relay key, if a bridge has registered one (046).
    func relayKey() -> Data? {
        guard let data = try? Data(contentsOf: locations.relay),
              let stored = try? StoreCoding.decoder.decode(DaemonAPI.RelayRegistration.self, from: data)
        else { return nil }
        return stored.publicKey
    }

    /// `relay/register`. An uncompressed P256 point or nothing: the daemon does not hold
    /// CryptoKit, and a key it hands every device must at least be the right shape.
    func registerRelayKey(_ key: Data) throws {
        guard key.count == 65, key.first == 0x04 else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "A relay key is an uncompressed P256 public key, 65 bytes.")
        }
        guard relayKey() != key else { return }
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(DaemonAPI.RelayRegistration(publicKey: key))
            .write(to: locations.relay, options: .atomic)
    }
}
