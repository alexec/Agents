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

/// A transport over two file descriptors.
///
/// Reading is done on a thread of its own rather than with `FileHandle.bytes`, because
/// these descriptors belong to processes that get killed: a blocking `read` returning
/// -1 is a state to handle, and an exception thrown out of Foundation on a closed
/// handle is not.
public final class FDTransport: LineTransport, @unchecked Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let writeLock = NSLock()
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let closed = ManagedAtomicFlag()

    /// Writing to a pipe whose other end has gone raises `SIGPIPE`, and the default
    /// disposition for that is to kill the process. Every descriptor this class writes
    /// to belongs to something that gets killed, so without this a runtime exiting at
    /// the wrong moment takes the daemon down and every agent with it. Ignored once,
    /// process-wide: `write` then returns `EPIPE`, which the loop below already knows
    /// what to do with.
    private static let ignoreBrokenPipes: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    public init(readFD: Int32, writeFD: Int32) {
        _ = Self.ignoreBrokenPipes
        self.readFD = readFD
        self.writeFD = writeFD
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        self.stream = AsyncThrowingStream { c = $0 }
        self.continuation = c
        startReading()
    }

    public convenience init(socket fd: Int32) {
        self.init(readFD: fd, writeFD: fd)
    }

    private func startReading() {
        let fd = readFD
        let continuation = self.continuation
        let thread = Thread {
            var splitter = LineSplitter()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { POSIX.read(fd, $0.baseAddress, $0.count) }
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
        guard !closed.isSet else { throw JSONRPCTransportError.closed }
        let data = Array((line + "\n").utf8)
        writeLock.lock()
        defer { writeLock.unlock() }
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

    public func close() {
        guard closed.set() else { return }
        continuation.finish()
        // A socket is shut down before it is closed. Closing alone does not wake a
        // thread blocked in `read` on it, and that thread would then read again from a
        // descriptor number the process may since have handed to something else.
        // Shutting down returns it zero at once. A pipe is not a socket, and the call
        // simply fails on one.
        if writeFD == readFD { shutdown(readFD, SHUT_RDWR) }
        POSIX.close(readFD)
        if writeFD != readFD { POSIX.close(writeFD) }
    }
}

/// Bytes in, whole lines out, each byte looked at once.
///
/// A daemon page can be one line of twenty megabytes, and it arrives a read at a time.
/// Searching the whole backlog for a newline after every read looked at the start of
/// that line some three hundred times; this remembers how far it has already looked.
/// Lines that are only whitespace are dropped and a trailing `\r` is left off, which
/// is what trimming the whole line did, without walking it twice to do it.
struct LineSplitter {
    private var pending: [UInt8] = []
    /// Where the next line starts.
    private var start = 0
    /// How far past `start` has been searched and found no newline.
    private var searched = 0
    /// Bytes handed to the newline search, over the splitter's life. At most every
    /// byte once; the tests hold it to that.
    private(set) var examined = 0

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        // Taken lines are dropped from the front only once they are most of the
        // buffer, so a burst of short lines does not shuffle the rest along each time.
        if start > 0, start >= pending.count / 2 {
            pending.removeSubrange(0..<start)
            searched -= start
            start = 0
        }
        pending.append(contentsOf: bytes)
    }

    mutating func next() -> String? {
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
