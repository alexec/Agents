// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// Frames in, frames out in order, each once (046, contracts/relay.md § Session).
///
/// iCloud promises neither order nor exactly once: a fetch can return the fifth frame
/// before the fourth, and a save retried after a timeout that had in fact gone through
/// is the same frame twice. The daemon's protocol is one line after another. So what
/// comes out of here is strictly by number: a frame already handed on is dropped, one
/// that is early is held, and a gap left open for `patience` ends the session — the
/// device then starts a new one, which is the same full refresh a reconnect is.
public struct FrameOrder: Sendable {
    public private(set) var next: Int64 = 0
    private var held: [Int64: Frame] = [:]
    private var heldSince: Date?
    public let patience: TimeInterval

    public init(patience: TimeInterval = 10) {
        self.patience = patience
    }

    /// Take a frame; get back every frame that can now be handed on, in order.
    public mutating func accept(_ frame: Frame, now: Date = Date()) -> [Frame] {
        guard frame.seq >= next, held[frame.seq] == nil else { return [] }
        held[frame.seq] = frame
        var ready: [Frame] = []
        while let frame = held.removeValue(forKey: next) {
            ready.append(frame)
            next += 1
        }
        heldSince = held.isEmpty ? nil : (ready.isEmpty ? (heldSince ?? now) : now)
        return ready
    }

    /// Whether a frame has been waiting on a missing one for longer than `patience`.
    public func gapExpired(now: Date = Date()) -> Bool {
        guard let heldSince else { return false }
        return now.timeIntervalSince(heldSince) > patience
    }
}
#endif
