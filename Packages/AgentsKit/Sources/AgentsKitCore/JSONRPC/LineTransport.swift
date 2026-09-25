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
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    pending.append(contentsOf: buffer[0..<n])
                    while let i = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = pending[pending.startIndex..<i]
                        pending = pending[pending.index(after: i)...]
                        let line = String(decoding: lineData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty { continuation.yield(line) }
                    }
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
                Darwin.write(writeFD, $0.baseAddress, $0.count)
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
        Darwin.close(readFD)
        if writeFD != readFD { Darwin.close(writeFD) }
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
