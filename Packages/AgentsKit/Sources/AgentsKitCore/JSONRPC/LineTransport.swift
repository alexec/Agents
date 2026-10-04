import Foundation

/// Something that carries one JSON object per line, in both directions.
///
/// Both halves of this app speak the same protocol over different pipes: ACP goes to a
/// runtime's stdin and stdout, and the app talks to the daemon over a Unix socket. One
/// transport protocol means the connection above it is written and tested once.
public protocol LineTransport: Sendable {
    func write(line: String) throws
    func lines() -> AsyncThrowingStream<String, any Error>
    func close()
}

/// A transport that can say why it closes: a WebSocket's close code and reason. The control
/// plane closes a forgotten client with 4403, so a browser knows at once (071).
public protocol ReasonedClose: Sendable {
    func close(code: UInt16, reason: String)
}

public extension LineTransport {
    /// Closes with `code` where the transport can say it, and plainly where it can't.
    func close(code: UInt16, reason: String) {
        if let reasoned = self as? any ReasonedClose { reasoned.close(code: code, reason: reason) } else { close() }
    }
}

/// A transport over two file descriptors.
///
/// Reading is done on a thread of its own rather than with `FileHandle.bytes`, because
/// these descriptors belong to processes that get killed: a blocking `read` returning
/// -1 is a state to handle, and an exception thrown out of Foundation on a closed
/// handle is not.
///
/// The reading thread owns the descriptor it reads (#209). `close` never closes it under
/// that thread, which would leave it blocked in `read` on a number the process may since
/// have handed to another runtime's pipe or a client's socket. It wakes the thread
/// instead: a socket is shut down, which returns its `read` zero, and a pipe — which
/// cannot be shut down — is read only once `poll` says so, beside a pipe of its own that
/// `close` closes. The thread lets the descriptor go as it leaves.
public final class FDTransport: LineTransport, @unchecked Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let ends: Ends
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private var closed: ManagedAtomicFlag { ends.closed }
    /// The line `lines()` gives in place of one longer than this, or nil for no limit.
    /// See `LineSplitter.cut`.
    public let maximumLine: Int?

    /// The longest line read from a runtime (#209). A tool result can be any size, and a
    /// line is held whole, parsed, written to the transcript and sent to every window;
    /// one past this is cut to a note instead.
    public static let runtimeLineLimit = 16 << 20
    /// The longest line read from a daemon.sock client (#209): a prompt with its largest
    /// attachment (25 MB, base64) fits, as it does on the control plane's WebSocket.
    public static let clientLineLimit = 64 << 20

    /// What the reading thread and `close` share, so the thread holds no reference to the
    /// transport and a transport dropped without closing still reaches `deinit`.
    private final class Ends: @unchecked Sendable {
        let closed = ManagedAtomicFlag()
        let writeLock = NSLock()
        /// A pipe's wake-up, read end and write end; -1 for a socket.
        var wake: (read: Int32, write: Int32) = (-1, -1)
        private let lock = NSLock()
        /// A socket is read and written on the one descriptor, so it is closed only once
        /// the thread has left and `close` has been called, whichever is last.
        private var holders = 2

        func letGoOfSocket(_ fd: Int32) {
            let last = lock.withLock { holders -= 1; return holders == 0 }
            guard last else { return }
            writeLock.withLock { _ = POSIX.close(fd) }
        }
    }

    /// Writing to a pipe whose other end has gone raises `SIGPIPE`, and the default
    /// disposition for that is to kill the process. Every descriptor this class writes
    /// to belongs to something that gets killed, so without this a runtime exiting at
    /// the wrong moment takes the daemon down and every agent with it. Ignored once,
    /// process-wide: `write` then returns `EPIPE`, which the loop below already knows
    /// what to do with.
    private static let ignoreBrokenPipes: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    public init(readFD: Int32, writeFD: Int32, maximumLine: Int? = nil) {
        _ = Self.ignoreBrokenPipes
        self.readFD = readFD
        self.writeFD = writeFD
        self.maximumLine = maximumLine
        self.ends = Ends()
        if readFD != writeFD {
            var wake: [Int32] = [-1, -1]
            if pipe(&wake) == 0 {
                for fd in wake { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
                ends.wake = (wake[0], wake[1])
            }
        }
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        self.stream = AsyncThrowingStream { c = $0 }
        self.continuation = c
        startReading()
    }

    public convenience init(socket fd: Int32, maximumLine: Int? = nil) {
        self.init(readFD: fd, writeFD: fd, maximumLine: maximumLine)
    }

    private func startReading() {
        let fd = readFD
        let isSocket = readFD == writeFD
        let ends = self.ends
        let continuation = self.continuation
        let maximumLine = self.maximumLine
        let thread = Thread {
            var splitter = LineSplitter(maximumLine: maximumLine, cutsLongLines: true)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            defer {
                if isSocket {
                    ends.letGoOfSocket(fd)
                } else {
                    POSIX.close(fd)
                    if ends.wake.read >= 0 { POSIX.close(ends.wake.read) }
                }
            }
            while true {
                if !isSocket, ends.wake.read >= 0 {
                    var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: ends.wake.read, events: Int16(POLLIN), revents: 0)]
                    let ready = poll(&fds, 2, -1)
                    if ready < 0 {
                        if errno == EINTR { continue }
                        continuation.finish(throwing: JSONRPCTransportError.closed)
                        return
                    }
                    // Closed: whatever the pipe still holds is nobody's now.
                    if fds[1].revents != 0 { continuation.finish(); return }
                }
                let n = buffer.withUnsafeMutableBytes { POSIX.read(fd, $0.baseAddress, $0.count) }
                // Read after a close is not ours to hand on.
                if ends.closed.isSet { continuation.finish(); return }
                if n > 0 {
                    buffer.withUnsafeBufferPointer { splitter.append(UnsafeBufferPointer(rebasing: $0[0..<n])) }
                    while let line = splitter.next() { continuation.yield(line) }
                } else if n == 0 {
                    continuation.finish()
                    return
                } else {
                    if errno == EINTR { continue }
                    continuation.finish(throwing: JSONRPCTransportError.closed)
                    return
                }
            }
        }
        thread.name = "AgentsKit.FDTransport"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    public func write(line: String) throws {
        let data = Array((line + "\n").utf8)
        ends.writeLock.lock()
        defer { ends.writeLock.unlock() }
        // Asked under the lock `close` closes under, so a write never lands on a number
        // given back a moment ago.
        guard !closed.isSet else { throw JSONRPCTransportError.closed }
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBufferPointer {
                POSIX.write(writeFD, $0.baseAddress, $0.count)
            }
            if written > 0 {
                offset += written
            } else {
                if errno == EINTR { continue }
                throw JSONRPCTransportError.writeFailed(errno: errno)
            }
        }
    }

    public func lines() -> AsyncThrowingStream<String, any Error> { stream }

    /// A transport dropped without being closed still gives its descriptors back
    /// (#163). `close` is a latch, so one already closed is left alone.
    deinit { close() }

    public func close() {
        guard closed.set() else { return }
        continuation.finish()
        if writeFD == readFD {
            // Shutting a socket down returns the reading thread's `read` zero at once,
            // and the last of the two to let go closes it.
            shutdown(readFD, SHUT_RDWR)
            ends.letGoOfSocket(readFD)
        } else {
            // The reading thread is woken by its pipe and closes `readFD` itself.
            ends.writeLock.withLock { _ = POSIX.close(writeFD) }
            if ends.wake.write >= 0 { POSIX.close(ends.wake.write) }
        }
    }
}

/// Bytes in, whole lines out, each byte looked at once.
///
/// A daemon page can be one line of twenty megabytes, and it arrives a read at a time.
/// Searching the whole backlog for a newline after every read looked at the start of
/// that line some three hundred times; this remembers how far it has already looked.
/// Lines that are only whitespace are dropped and a trailing `\r` is left off, which
/// is what trimming the whole line did, without walking it twice to do it.
///
/// Every reader of lines uses it — the socket, the phone's network link, the bridge.
/// The network two kept their own copy of the old search until 2026-09-25, and a
/// phone reading `agents/list` in Wi‑Fi-sized pieces spent seconds on it.
public struct LineSplitter {
    private var pending: [UInt8] = []
    /// Where the next line starts.
    private var start = 0
    /// How far past `start` has been searched and found no newline.
    private var searched = 0
    /// Bytes handed to the newline search, over the splitter's life. At most every
    /// byte once; the tests hold it to that.
    private(set) var examined = 0
    /// The longest line it will wait for, or nil for no limit.
    public let maximumLine: Int?
    /// A line ran past `maximumLine` without ending. Nothing after it can be trusted to
    /// start where a line starts, so the reader should give up on the connection.
    /// Never set by a splitter that cuts long lines.
    public private(set) var overflowed = false
    /// Whether a line past `maximumLine` is cut rather than given up on. See `cut`.
    public let cutsLongLines: Bool
    /// The line being cut: its first bytes, kept to say what it was, and its length so far.
    private var cutting: (start: [UInt8], bytes: Int)?
    /// Cut lines' stand-ins, to come out of `next` before anything read after them.
    private var cuts: [String] = []
    /// How much of a cut line is kept to say what it was.
    static let cutStartKept = 512

    /// `maximumLine` is for a reader whose other end is not ours to trust: without it,
    /// a peer that never sends a newline is kept, byte by byte, for as long as it likes.
    ///
    /// `cutsLongLines` is for a peer that is ours but says whatever its tools say: a
    /// runtime, or a window (#209). A line past the limit is not held; the rest of it is
    /// skipped up to its newline, and `next` gives a stand-in for it in its place — a
    /// `jsonrpc/lineCut` notification saying how long it was and how it began (see
    /// `cut`). The lines after it are read as ever.
    public init(maximumLine: Int? = nil, cutsLongLines: Bool = false) {
        self.maximumLine = maximumLine
        self.cutsLongLines = cutsLongLines
    }

    /// The method a cut line's stand-in arrives under. Never sent by anybody: it is made
    /// here, and `JSONRPCConnection` answers for the line it replaced.
    public static let cutMethod = "jsonrpc/lineCut"

    /// The stand-in for a line of `bytes` bytes that began with `start`.
    public static func cut(start: [UInt8], bytes: Int, limit: Int) -> String {
        let params: JSONValue = .object([
            "bytes": .int(bytes),
            "limit": .int(limit),
            "start": .string(String(decoding: start, as: UTF8.self)),
        ])
        return (try? JSONRPCCodec.encode(.notification(method: cutMethod, params: params)))
            ?? #"{"jsonrpc":"2.0","method":"\#(cutMethod)"}"#
    }

    public mutating func append(_ data: Data) {
        data.withUnsafeBytes { append($0.bindMemory(to: UInt8.self)) }
    }

    public mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        var bytes = bytes
        if cutting != nil {
            // Skipped up to its newline; what follows the newline is read as ever.
            guard let base = bytes.baseAddress, !bytes.isEmpty,
                  let hit = memchr(base, Int32(UInt8(ascii: "\n")), bytes.count) else {
                cutting!.bytes += bytes.count
                return
            }
            let end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            cutting!.bytes += end
            cuts.append(Self.cut(start: cutting!.start, bytes: cutting!.bytes, limit: maximumLine ?? 0))
            cutting = nil
            bytes = UnsafeBufferPointer(rebasing: bytes[(end + 1)...])
        }
        // Taken lines are dropped from the front only once they are most of the
        // buffer, so a burst of short lines does not shuffle the rest along each time.
        if start > 0, start >= pending.count / 2 {
            pending.removeSubrange(0..<start)
            searched -= start
            start = 0
        }
        guard !overflowed else { return }
        pending.append(contentsOf: bytes)
        if let maximumLine, pending.count - start > maximumLine, !hasNewline(from: searched) {
            if cutsLongLines {
                // Nothing before `start` is waiting and nothing after it ends, so all of
                // what is held is the one long line.
                let kept = pending[start..<min(pending.count, start + Self.cutStartKept)]
                cutting = (Array(kept), pending.count - start)
            } else {
                overflowed = true
            }
            pending = []
            start = 0
            searched = 0
        }
    }

    /// Whether a line ends somewhere past `from`. Not counted in `examined`: `next`
    /// searches the same bytes again, and only a splitter over its limit asks.
    private func hasNewline(from: Int) -> Bool {
        pending.withUnsafeBufferPointer { all in
            from < all.count && memchr(all.baseAddress! + from, Int32(UInt8(ascii: "\n")), all.count - from) != nil
        }
    }

    public mutating func next() -> String? {
        if !cuts.isEmpty { return cuts.removeFirst() }
        while true {
            let found: Int? = pending.withUnsafeBufferPointer { all in
                let from = searched
                guard from < all.count,
                      let hit = memchr(all.baseAddress! + from, Int32(UInt8(ascii: "\n")), all.count - from)
                else { return nil }
                return all.baseAddress!.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            }
            examined += (found.map { $0 + 1 } ?? pending.count) - searched
            guard let end = found else {
                searched = pending.count
                return nil
            }
            let line = pending.withUnsafeBufferPointer { all -> String? in
                var last = end
                while last > start, Self.isSpace(all[last - 1]) { last -= 1 }
                var first = start
                while first < last, Self.isSpace(all[first]) { first += 1 }
                guard first < last else { return nil }
                return String(decoding: UnsafeBufferPointer(rebasing: all[first..<last]), as: UTF8.self)
            }
            start = end + 1
            searched = start
            if let line { return line }
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

/// A one-way latch, so closing twice is not an error and cannot double-close a
/// descriptor that some other process has since been given.
public final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Sets the flag. Returns true only for the caller that set it.
    @discardableResult
    public func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// A transport that goes nowhere but a matching one, for tests.
public final class PairedTransport: LineTransport, @unchecked Sendable {
    private let outbound: AsyncThrowingStream<String, any Error>.Continuation
    private let inbound: AsyncThrowingStream<String, any Error>
    private let closed = ManagedAtomicFlag()

    private init(outbound: AsyncThrowingStream<String, any Error>.Continuation,
                 inbound: AsyncThrowingStream<String, any Error>) {
        self.outbound = outbound
        self.inbound = inbound
    }

    /// Two transports wired to each other: what one writes, the other reads.
    public static func pair() -> (PairedTransport, PairedTransport) {
        var aContinuation: AsyncThrowingStream<String, any Error>.Continuation!
        let aStream = AsyncThrowingStream<String, any Error> { aContinuation = $0 }
        var bContinuation: AsyncThrowingStream<String, any Error>.Continuation!
        let bStream = AsyncThrowingStream<String, any Error> { bContinuation = $0 }
        let a = PairedTransport(outbound: bContinuation, inbound: aStream)
        let b = PairedTransport(outbound: aContinuation, inbound: bStream)
        return (a, b)
    }

    public func write(line: String) throws {
        guard !closed.isSet else { throw JSONRPCTransportError.closed }
        // Blank lines are not messages, and are dropped here exactly as FDTransport
        // drops them, so a test against a pair sees what a real pipe would show.
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        outbound.yield(trimmed)
    }

    public func lines() -> AsyncThrowingStream<String, any Error> { inbound }

    public func close() {
        guard closed.set() else { return }
        outbound.finish()
    }
}
