// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// The Mac's side of a relayed session gathers lines before it posts them (046, R6).
///
/// At home a busy turn is dozens of `agent/entry` lines a second, and each one costs
/// nothing. Through iCloud each post is a request against a budget of about forty a
/// second for the person's whole account. So lines wait here: a batch goes
/// `window` after its first line, or as soon as it holds `limit` bytes, whichever comes
/// first. That turns a busy turn into two or three posts a second, and a quiet one into
/// a post that is at most `window` late.
public struct LineBatcher: Sendable {
    public let window: TimeInterval
    public let limit: Int
    private var waiting: [String] = []
    private var bytes = 0
    private var firstAt: Date?

    public init(window: TimeInterval = 0.4, limit: Int = 256 * 1024) {
        self.window = window
        self.limit = limit
    }

    /// When the batch waiting now must go, or `nil` when nothing waits.
    public var deadline: Date? { firstAt.map { $0.addingTimeInterval(window) } }

    public var isEmpty: Bool { waiting.isEmpty }

    /// Add a line. Returns a batch when this line filled one.
    public mutating func append(_ line: String, now: Date = Date()) -> [String]? {
        let size = line.utf8.count + 1
        var full: [String]?
        // A line that would take the batch past the limit starts the next one, so no
        // batch but a single huge line is ever over it.
        if !waiting.isEmpty, bytes + size > limit { full = take() }
        if waiting.isEmpty { firstAt = now }
        waiting.append(line)
        bytes += size
        if full == nil, bytes >= limit { full = take() }
        return full
    }

    /// The waiting batch, if its time has come.
    public mutating func takeIfDue(now: Date = Date()) -> [String]? {
        guard let deadline, now >= deadline else { return nil }
        return take()
    }

    /// Whatever is waiting, now.
    public mutating func flush() -> [String]? {
        waiting.isEmpty ? nil : take()
    }

    private mutating func take() -> [String] {
        defer { waiting = []; bytes = 0; firstAt = nil }
        return waiting
    }
}
#endif
