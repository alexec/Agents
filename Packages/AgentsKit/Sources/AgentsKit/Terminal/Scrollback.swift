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
    /// The bytes held, in a ring once it is full: `start` is where the oldest is.
    /// Appending to a full buffer overwrites the oldest in place rather than shifting
    /// all four megabytes down under the session's lock on every chunk (#401).
    private var storage: [UInt8]
    private var start = 0
    /// How many bytes have been dropped off the front over this buffer's life. Non-zero
    /// means the shell printed more than the cap, and the pane says so rather than
    /// implying the replay is the whole session.
    public private(set) var dropped: Int = 0

    public init(cap: Int = defaultCap) {
        self.cap = cap
        self.storage = []
        self.storage.reserveCapacity(min(cap, 64 * 1024))
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var hasDropped: Bool { dropped > 0 }
    /// How many bytes the shell has printed in all: the offset just past the last one
    /// held. A screen that knows how far it has got drops what it has already shown.
    public var end: Int { dropped + storage.count }

    public mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        // More than the whole cap in one go: only the tail of it can survive, and
        // everything already held is gone.
        if data.count >= cap {
            dropped += storage.count + (data.count - cap)
            storage = Array(data.suffix(cap))
            start = 0
            return
        }
        var rest = data[...]
        // Filling up to the cap.
        if storage.count < cap {
            let room = cap - storage.count
            storage.append(contentsOf: rest.prefix(room))
            rest = rest.dropFirst(room)
        }
        // Full: each new byte takes the oldest one's place.
        while !rest.isEmpty {
            let run = min(rest.count, cap - start)
            storage.replaceSubrange(start..<(start + run), with: rest.prefix(run))
            rest = rest.dropFirst(run)
            start = (start + run) % cap
            dropped += run
        }
    }

    /// Everything held, oldest first. What a window replays on attach.
    public var tail: Data {
        guard start > 0 else { return Data(storage) }
        var out = Data(capacity: storage.count)
        out.append(contentsOf: storage[start...])
        out.append(contentsOf: storage[..<start])
        return out
    }

    /// The last `limit` bytes, for a window that wants less than the whole buffer.
    public func tail(limit: Int) -> Data {
        let all = tail
        guard limit < all.count else { return all }
        return all.suffix(limit)
    }

    public static func == (lhs: Scrollback, rhs: Scrollback) -> Bool {
        lhs.cap == rhs.cap && lhs.dropped == rhs.dropped && lhs.tail == rhs.tail
    }

    public mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        start = 0
        dropped = 0
    }
}
