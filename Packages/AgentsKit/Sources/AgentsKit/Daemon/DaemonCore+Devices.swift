import AgentsKitCore
import Foundation

/// Pairing (021 US5): who may be told.
///
/// A device announces itself once with its public key, and from then on it is routed
/// to and sealed to. There is no approving and no revoking (Alex, 2026-09-21): the
/// announce arrives over the person's own network and the mailbox is their own iCloud
/// account, so a device that can announce is already theirs. A device that is gone
/// simply stops being heard from, and the staleness rung stops choosing it.
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
}
