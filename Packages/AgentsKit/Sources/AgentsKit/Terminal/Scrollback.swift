import Foundation

/// What a shell has printed, capped.
///
/// Raw bytes, never parsed. The daemon holds this and nothing else about a screen,
/// because feeding the same bytes in any chunking gives the same screen: a byte buffer
/// is a complete description of one. That was proved before the design was settled, and
/// it is why emulation lives in the app and not here (plan decision 2).
///
/// Dropping is from the front, so what comes back is the end of the output, which is
/// the part anyone wants after an hour away.
public struct Scrollback: Sendable, Equatable {
    /// Enough to hold what a long build prints, and bounded so something pathological
    /// cannot take the daemon's memory with it.
    ///
    /// Measured rather than guessed: a full clean `xcodebuild` of this project prints
    /// about 350KB, so this holds roughly eleven of them. A shell that prints more than
    /// that gives back the end, and says it has dropped the rest.
    public static let defaultCap = 4 * 1024 * 1024

    public let cap: Int
    private(set) var bytes: Data
    /// How many bytes have been dropped off the front over this buffer's life. Non-zero
    /// means the shell printed more than the cap, and the pane says so rather than
    /// implying the replay is the whole session.
    public private(set) var dropped: Int = 0

    public init(cap: Int = defaultCap) {
        self.cap = cap
        self.bytes = Data()
        self.bytes.reserveCapacity(min(cap, 64 * 1024))
    }

    public var count: Int { bytes.count }
    public var isEmpty: Bool { bytes.isEmpty }
    public var hasDropped: Bool { dropped > 0 }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        // More than the whole cap in one go: only the tail of it can survive, and
        // everything already held is gone.
        if data.count >= cap {
            dropped += bytes.count + (data.count - cap)
            bytes = data.suffix(cap)
            return
        }
        bytes.append(data)
        if bytes.count > cap {
            let excess = bytes.count - cap
            bytes.removeFirst(excess)
            dropped += excess
        }
    }

    /// Everything held, oldest first. What a window replays on attach.
    public var tail: Data { bytes }

    /// The last `limit` bytes, for a window that wants less than the whole buffer.
    public func tail(limit: Int) -> Data {
        guard limit < bytes.count else { return bytes }
        return bytes.suffix(limit)
    }

    public mutating func clear() {
        bytes.removeAll(keepingCapacity: true)
        dropped = 0
    }
}
