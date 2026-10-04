import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Where `agents-control` says what happened (#174): every line stamped with the time and
/// its zone (ISO 8601, to the millisecond), and the file rolled to `<name>.previous.log`
/// past `limit`, as the daemon's log is.
///
/// Given a file, it becomes the process's standard output and error, so what is written
/// without it (a trap, a library's warning) still lands there, unstamped. Without one,
/// lines go to standard error, stamped, for whatever collects them on a server.
public final class ControlLog: @unchecked Sendable {
    public static let shared = ControlLog()
    public static let limit = 4 * 1024 * 1024

    private let lock = NSLock()
    private var file: URL?
    private var limit = ControlLog.limit
    /// Standard error, or the file's own descriptor when it isn't the process's streams.
    private var fd: Int32 = 2
    private var standardStreams = true
    private let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    public init() {}

    /// Whether a file was given: what `agents-control serve --log` writes to.
    public var isTaken: Bool { lock.withLock { file != nil } }

    /// Writes to `file` from now on: through standard output and error, unless a test
    /// says not.
    public func take(_ file: URL, limit: Int = ControlLog.limit, standardStreams: Bool = true) {
        lock.withLock {
            self.file = file
            self.limit = limit
            self.standardStreams = standardStreams
            reopen()
        }
    }

    public func write(_ line: String, at date: Date = Date()) {
        lock.withLock {
            if file != nil { rollIfNeeded() }
            let text = Data(Self.stamped(line, stamp.string(from: date)).utf8)
            text.withUnsafeBytes { buffer in
                var at = 0
                while at < buffer.count {
                    let wrote = Foundation.write(fd, buffer.baseAddress! + at, buffer.count - at)
                    if wrote <= 0 { break }
                    at += wrote
                }
            }
        }
    }

    /// Each line of a message stamped, so a multi-line error stays readable by line.
    static func stamped(_ message: String, _ stamp: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(stamp) \($0)\n" }.joined()
    }

    private func rollIfNeeded() {
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) > limit, let file else { return }
        let previous = file.deletingPathExtension().appendingPathExtension("previous.log")
        _ = rename(file.path, previous.path)
        reopen()
    }

    private func reopen() {
        guard let file else { return }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        if standardStreams {
            dup2(fd, 1)
            dup2(fd, 2)
            close(fd)
        } else {
            if self.fd != 2 { close(self.fd) }
            self.fd = fd
        }
    }
}
