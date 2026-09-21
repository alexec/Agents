import AgentsKitCore
import Foundation

/// Pairing (021 US5): who may be told, and how a device stops being one.
///
/// A device announces itself once with its public key and waits; the person says yes
/// at the Mac; from then on it is routed to and sealed to. Revoking is **deletion**:
/// the record goes and the device's mailbox is emptied, so anything already waiting is
/// discarded unread (FR-021). Deletion is what makes the device unable to read anything
/// — there is no flag somebody must remember to check, here or in `Routing`.
extension DaemonCore {
    /// Every record, read from disk the first time it is wanted.
    var devices: [UUID: Device] {
        if let loadedDevices { return loadedDevices }
        let loaded = Dictionary(deviceStore.load().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loadedDevices = loaded
        return loaded
    }

    func device(_ id: UUID) -> Device? { devices[id] }

    /// The only devices the ladder may see. An announced-and-waiting device is not
    /// here, and neither is a revoked one, because it no longer exists.
    var approvedDevices: [Device] { devices.values.filter(\.isApproved) }

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
    /// its record back, whatever state it is in. The same id with a **different** key
    /// is refused: a key never changes under an identity, and a device that wants a
    /// new key is a new device with a new id.
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
        return made
    }

    /// `devices/approve`. Approving again is not an error and does not move the date.
    func approveDevice(_ id: UUID) throws -> Device {
        guard var known = device(id) else { throw noSuchDevice(id) }
        if known.approvedAt == nil {
            known.approvedAt = now()
            try saveDevice(known)
            reconsider()
        }
        return known
    }

    /// `devices/revoke`: the record goes, the mailbox is emptied, and anything showing on
    /// that device is decided again without it.
    func revokeDevice(_ id: UUID) throws {
        guard device(id) != nil else { throw noSuchDevice(id) }
        var all = devices
        all.removeValue(forKey: id)
        loadedDevices = all
        try deviceStore.save(Array(all.values))
        broadcast(DaemonAPI.Notification.deviceChanged, DaemonAPI.DeviceNotification(gone: id))
        let mailbox = mailbox
        let previous = mailboxTail
        mailboxTail = Task {
            await previous?.value
            try? await mailbox.empty(device: id)
        }
        // Whatever was showing there is now showing nowhere, and every surface hears so
        // — then the ladder decides again as though the device had never been.
        let outstanding = needs()
        for (needID, delivery) in deliveries where delivery.to == .device(id) {
            var moved = delivery
            moved.to = nil
            deliveries[needID] = moved
            broadcast(DaemonAPI.Notification.attentionChanged,
                      DaemonAPI.AttentionNotification(needID: needID, need: outstanding.first { $0.id == needID },
                                                      to: nil, alert: false))
        }
        reconsider()
    }

    private func noSuchDevice(_ id: UUID) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.noSuchDevice, message: "No device \(id.uuidString) is paired.")
    }
}
