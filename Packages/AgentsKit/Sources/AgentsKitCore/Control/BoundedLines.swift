import Foundation

/// Lines on their way to one reader, counted in bytes (#167). An unbounded stream let a
/// reader that fell behind hold everything the other end sent; this one says when what
/// waits passes `high`, and again once the reader has brought it down to `low`, so the
/// transport can stop reading its socket (and let TCP push back) or give up on the sender.
///
/// One line larger than `high` still passes when nothing else is waiting: the cap is on a
/// backlog, not on a message.
public final class BoundedLines: @unchecked Sendable {
    public let high: Int
    public let low: Int
    private let onHigh: @Sendable () -> Void
    private let onLow: @Sendable () -> Void
    private let lock = NSLock()
    private var waiting = 0
    private var over = false
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let iterator: Iterator

    private final class Iterator: @unchecked Sendable {
        var inner: AsyncThrowingStream<String, any Error>.AsyncIterator
        init(_ stream: AsyncThrowingStream<String, any Error>) { inner = stream.makeAsyncIterator() }
    }

    public init(high: Int, low: Int, onHigh: @escaping @Sendable () -> Void, onLow: @escaping @Sendable () -> Void = {}) {
        self.high = high
        self.low = low
        self.onHigh = onHigh
        self.onLow = onLow
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        let stream = AsyncThrowingStream<String, any Error>(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        iterator = Iterator(stream)
    }

    /// Bytes handed over and not yet read.
    public var bytesWaiting: Int { lock.withLock { waiting } }

    public func yield(_ line: String) {
        let size = line.utf8.count
        let crossed = lock.withLock { () -> Bool in
            let before = waiting
            waiting += size
            guard !over, before > 0, waiting > high else { return false }
            over = true
            return true
        }
        continuation.yield(line)
        if crossed { onHigh() }
    }

    public func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }

    /// The lines, read on demand: a line is counted off only once the reader has taken it.
    /// One reader only, as for any line transport.
    public var lines: AsyncThrowingStream<String, any Error> {
        let iterator = self.iterator
        return AsyncThrowingStream(unfolding: { [self] in
            guard let line = try await iterator.inner.next() else { return nil }
            let size = line.utf8.count
            let fell = lock.withLock { () -> Bool in
                waiting -= size
                guard over, waiting <= low else { return false }
                over = false
                return true
            }
            if fell { onLow() }
            return line
        })
    }
}
