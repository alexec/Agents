import Foundation

/// Whether a device forgets its pairing over a refusal, or dials again (#81).
///
/// `forgotten` is a person's decision in a window, and is final. `unknown` is final only
/// when it lasts: a control plane starting up, or one copy that has not yet read a pairing
/// made at another, said it for a moment, and a phone that forgot then had to be paired
/// again by QR. Everything else, `unavailable` included, is a dial that failed.
public struct RefusalPatience: Sendable {
    /// How long `unknown` has to keep coming back, with no connection between, before the
    /// device believes it.
    public var patience: TimeInterval
    private var firstUnknown: Date?

    public init(patience: TimeInterval = 120) {
        self.patience = patience
    }

    /// True when the device should forget its pairing and ask for a new code.
    public mutating func forgets(after reason: ControlAuth.Reason, at now: Date = Date()) -> Bool {
        switch reason {
        case .forgotten:
            return true
        case .unknown:
            guard let first = firstUnknown else {
                firstUnknown = now
                return false
            }
            return now.timeIntervalSince(first) >= patience
        default:
            return false
        }
    }

    /// A connection was made: any `unknown` before it was a moment, not a verdict.
    public mutating func connected() {
        firstUnknown = nil
    }
}
