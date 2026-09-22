import Foundation

/// Where a need should be showing, and whether the person may be buzzed about it.
public struct Decision: Hashable, Sendable {
    /// Where it should be showing; `nil` means nowhere reachable, or silence because the
    /// conversation is being watched.
    public var to: Surface?
    /// Whether the person may be alerted afresh now, or should see it quietly.
    public var alert: Bool
    /// Hold: the person is at the Mac and the settling pause has not elapsed. Nothing is
    /// delivered while this is true; the caller re-decides when the pause is over.
    public var wait: Bool

    public init(to: Surface?, alert: Bool, wait: Bool) {
        self.to = to
        self.alert = alert
        self.wait = wait
    }
}

/// The ladder: one pure function, total over its inputs, and the only place any of
/// FR-005 through FR-014 is decided (FR-012). No surface may decide for itself whether it
/// is the right one to alert.
///
/// Pure: no clock of its own, no I/O, no platform. `now` is passed in, which is what lets
/// every rung be exhausted in a unit test with no phone in the room.
public enum Routing {
    /// The rungs, in order. The first that applies wins and nothing below it is consulted.
    ///
    /// 0. **Already met** — `outstanding` is false: no delivery, ever (FR-015).
    /// 1. **Being watched** — *any* presence is active and watching this conversation:
    ///    `to = nil`. Any surface, not the one that would otherwise win, because the rule
    ///    is about the conversation being watched and not about which machine watches
    ///    it: watching on the iPad silences the phone (US3 scenario 3).
    /// 2. **At the Mac** — the Mac is present, active and touched inside `macIdle`: `.mac`.
    ///    Inside the settling pause this is `wait` rather than a delivery.
    /// 3. **The device in hand** — the paired device that may notify and was heard from
    ///    most recently inside `deviceStaleness`.
    /// 4. **The default** — the most recently used paired iPhone that may notify.
    /// 5. **Nowhere** — `to = nil`. Not a failure: the need stays outstanding, and the next
    ///    surface to connect is told through `attention/pending` (FR-010, amended).
    public static func decide(need: Need,
                              outstanding: Bool = true,
                              presences: [Surface: Presence],
                              devices: [Device],
                              delivery: Delivery?,
                              thresholds: AttentionThresholds,
                              now: Date) -> Decision {
        guard outstanding else { return Decision(to: nil, alert: false, wait: false) }

        // 1. Being watched, anywhere.
        if presences.values.contains(where: { $0.isWatching(need.agentID) }) {
            return Decision(to: nil, alert: false, wait: false)
        }

        // 2. At the Mac — with the pause, which applies only here (FR-013): a person who
        //    is not at the Mac is not about to look at it.
        if let mac = presences[.mac], mac.isHere(now: now, thresholds: thresholds) {
            let settling = now.timeIntervalSince(need.raisedAt) < thresholds.settlingPause
            if settling { return Decision(to: .mac, alert: false, wait: true) }
            return Decision(to: .mac, alert: alert(for: .mac, delivery: delivery, thresholds: thresholds, now: now),
                            wait: false)
        }

        let eligible = devices.filter(\.isEligible)

        // 3. The device in hand: the eligible device heard from most recently and
        //    recently enough. Ties are decided here rather than left to `max(by:)`'s
        //    stability: later `heardAt` wins, and on an exact tie the iPhone, because that
        //    is the default the person asked for.
        let inHand = presences.values
            .filter { $0.isRecent(now: now, thresholds: thresholds) }
            .compactMap { presence -> (Presence, Device)? in
                guard let id = presence.surface.deviceID,
                      let device = eligible.first(where: { $0.id == id }) else { return nil }
                return (presence, device)
            }
        if let (presence, _) = Self.latest(inHand) {
            return Decision(to: presence.surface,
                            alert: alert(for: presence.surface, delivery: delivery, thresholds: thresholds, now: now),
                            wait: false)
        }

        // 4. The default: the most recently used eligible iPhone. `unknown` is never the
        //    default, because FR-009 names the iPhone and a device that will not say what
        //    it is cannot be it.
        let iPhones = eligible.filter { $0.kind == .iPhone }
        if let phone = iPhones.max(by: { ($0.lastSeenAt ?? .distantPast, $0.id.uuidString)
                                        < ($1.lastSeenAt ?? .distantPast, $1.id.uuidString) }) {
            let to = Surface.device(phone.id)
            return Decision(to: to, alert: alert(for: to, delivery: delivery, thresholds: thresholds, now: now),
                            wait: false)
        }

        // 5. Nowhere.
        return Decision(to: nil, alert: false, wait: false)
    }

    /// `to` says where the notification should *be*; this says whether the person may be
    /// *buzzed*. They differ on a move, and that difference is the whole of FR-018: a move
    /// inside the interval still moves the notification — the old surface withdraws, the
    /// new one shows it — but shows it silently.
    static func alert(for to: Surface, delivery: Delivery?, thresholds: AttentionThresholds, now: Date) -> Bool {
        guard let delivery else { return true }
        guard delivery.to != to else { return false }
        return now.timeIntervalSince(delivery.alertedAt) >= thresholds.reAlertInterval
    }

    /// The most recently heard of several, with the tie the contract names.
    private static func latest(_ candidates: [(Presence, Device)]) -> (Presence, Device)? {
        candidates.max { a, b in
            if a.0.heardAt != b.0.heardAt { return a.0.heardAt < b.0.heardAt }
            // Same instant: the iPhone wins. Both or neither an iPhone: the id, so the
            // answer is at least the same twice.
            let aPhone = a.1.kind == .iPhone, bPhone = b.1.kind == .iPhone
            if aPhone != bPhone { return bPhone }
            return a.1.id.uuidString < b.1.id.uuidString
        }
    }
}
