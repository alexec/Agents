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
