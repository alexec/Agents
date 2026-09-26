import AgentsKitCore
import Foundation

/// Pairing (021 US5): who may be told, and (046) who may reach this Mac from away.
///
/// A device announces itself once with its public key, and from then on it is routed
/// to and sealed to. There is still no approving (Alex, 2026-09-21, confirmed for 046's
/// D1): the announce arrives over the person's own network, so a device that can
/// announce is already theirs, and it is handed the Mac's relay key in the reply. There
/// is forgetting since 046: a paired device can drive agents from anywhere through the
/// relay, so a lost one has to be able to be cut off (FR-008). A forgotten device that
/// announces again at home is paired again.
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
    func announce(_ announcement: DaemonAPI.DeviceAnnouncement) throws -> Device {
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
