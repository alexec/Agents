import Foundation

/// Which device a host's unsealed need is sealed to (058, R6).
///
/// The ladder is the same one a daemon runs for its own devices. What changed is the
/// presences: they are every client's, whichever host that client was talking to, so
/// two hosts cannot each buzz a phone about the same moment.
public enum ControlNotices {
    /// The device to seal to, and whether the person may be buzzed. Nil when the person
    /// is at a screen, watching the conversation, or no device can be told — nothing
    /// is sealed then.
    public static func device(for need: Need, presences: [Surface: Presence], devices: [Device],
                              delivery: Delivery?, now: Date,
                              thresholds: AttentionThresholds = .standard) -> (id: UUID, alert: Bool)? {
        let decision = Routing.decide(need: need, presences: presences, devices: devices,
                                      delivery: delivery, thresholds: thresholds, now: now)
        guard !decision.wait, let id = decision.to?.deviceID else { return nil }
        return (id, decision.alert)
    }
}

/// What a copy has sent to its relay host for each need, so the same need said again
/// does not buzz twice, and a need that moves to another device, or ends, takes its
/// banner down (058, T097). `MailboxTransport` kept this beside the mailbox; the choice
/// is the control plane's now, and only the sealing is the relay host's.
public actor NoticeDesk {
    private struct Posted {
        var device: UUID
        var alert: Bool
        var at: Date
    }
    private var postedTo: [NeedID: Posted] = [:]

    public init() {}

    /// A host's `attention/need`: the deliveries it makes, in order. Nothing when nobody
    /// is to be told anew.
    public func heard(_ message: DaemonAPI.AttentionNeed, presences: [Surface: Presence], devices: [Device],
                      now: Date = Date()) -> [DaemonAPI.RelayDelivery] {
        if let id = message.withdraw { return withdraw(id) }
        guard let need = message.need else { return [] }
        guard let chosen = ControlNotices.device(for: need, presences: presences, devices: devices,
                                                 delivery: delivery(of: need.id), now: now),
              let device = devices.first(where: { $0.id == chosen.id }) else {
            return withdraw(need.id)
        }
        var out: [DaemonAPI.RelayDelivery] = []
        if let previous = postedTo[need.id] {
            if previous.device == chosen.id {
                // Same device: a later decision that would show it quietly must not replace
                // the banner, and one that would buzz again is the ladder saying the interval passed.
                if previous.alert || !chosen.alert { return [] }
            } else {
                out.append(DaemonAPI.RelayDelivery(needID: need.id, device: previous.device))
            }
        }
        postedTo[need.id] = Posted(device: chosen.id, alert: chosen.alert, at: now)
        out.append(DaemonAPI.RelayDelivery(needID: need.id, device: chosen.id, publicKey: device.publicKey,
                                           headline: message.headline ?? need.headline, alert: chosen.alert))
        return out
    }

    private func delivery(of id: NeedID) -> Delivery? {
        guard let posted = postedTo[id] else { return nil }
        return Delivery(needID: id, to: .device(posted.device), alertedAt: posted.at,
                        alertCount: posted.alert ? 1 : 0)
    }

    private func withdraw(_ id: NeedID) -> [DaemonAPI.RelayDelivery] {
        guard let previous = postedTo.removeValue(forKey: id) else { return [] }
        return [DaemonAPI.RelayDelivery(needID: id, device: previous.device)]
    }
}

/// The Needs you count each host says, added up for the devices (#1163), and what each
/// device was last told, so a device hears the count when it moves and not otherwise.
///
/// A host says its count with every need it offers or withdraws, and alone when it
/// moves with neither: a need met at the Mac, a finish read. The phone's widget and
/// badge show this number, so they move when the Mac's do.
public actor CountDesk {
    private var byHost: [HostID: Int] = [:]
    private var told: [UUID: Int] = [:]
    private var flushing = false

    public init() {}

    /// Every host's count, added up. Nil until a host has said one: an older host says
    /// none, and a zero would be a claim nobody made.
    public var total: Int? { byHost.isEmpty ? nil : byHost.values.reduce(0, +) }

    /// A host's count. Returns whether the total moved.
    @discardableResult
    public func heard(_ host: HostID, waiting: Int) -> Bool {
        let before = total
        byHost[host] = max(0, waiting)
        return total != before
    }

    /// Whether the caller is to send what is owed after a moment: one send for a burst.
    public func startFlush() -> Bool {
        guard !flushing else { return false }
        flushing = true
        return true
    }

    /// The counts owed: each device not told the total yet. Ends a flush.
    public func owed(to devices: [UUID], now: Date = Date()) -> [DaemonAPI.RelayCount] {
        flushing = false
        guard let total else { return [] }
        let owed = devices.filter { told[$0] != total }
        for device in owed { told[device] = total }
        return owed.map { DaemonAPI.RelayCount(device: $0, waiting: total, countedAt: now) }
    }

    /// A device told the count another way: on a need's own push.
    public func told(_ device: UUID, _ waiting: Int) {
        told[device] = waiting
    }

    /// A relay host came, or the devices changed: every device is owed the count again.
    public func forgetTold() {
        told = [:]
    }
}
