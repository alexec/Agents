import Foundation

/// Where the daemon says what happened. Rolled, because it outlives every window and a
/// long-lived writer with no limit fills a disk eventually.
///
/// One handle, kept open for appending, and one formatter (#177): a runtime that floods
/// stderr writes here per chunk, and opening, seeking and closing the file and building
/// a formatter for each line cost more than the line. The size is counted as lines are
/// written, so rolling needs no `stat`; the path is looked at again every
/// `checkEvery` lines, so a log moved or removed by hand is started afresh.
public final class DaemonLog: @unchecked Sendable {
    public static let shared = DaemonLog()

    private let lock = NSLock()
    private var url: URL?
    private let limit: Int
    private var handle: FileHandle?
    /// The open file's size, as written.
    private var size = 0
    /// The open file's inode, to tell when the path no longer names it.
    private var inode: UInt64 = 0
    private var sinceCheck = 0
    private let checkEvery = 256
    private let formatter = ISO8601DateFormatter()

    init(limit: Int = 4 * 1024 * 1024) {
        self.limit = limit
    }

    deinit { try? handle?.close() }

    public func setDestination(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        close()
        self.url = url
    }

    public func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let url else { return }
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        if handle != nil, size + line.count > limit { roll(url) }
        if handle != nil {
            sinceCheck += 1
            if sinceCheck >= checkEvery { sinceCheck = 0; if Self.inode(of: url) != inode { close() } }
        }
        guard let handle = handle ?? openLog(url) else { return }
        do {
            try handle.write(contentsOf: line)
            size += line.count
        } catch {
            close()
        }
    }

    /// The log, opened for appending, with its size and inode noted.
    private func openLog(_ url: URL, rolling: Bool = true) -> FileHandle? {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        if fstat(fd, &info) == 0 {
            size = Int(info.st_size)
            inode = UInt64(info.st_ino)
        }
        if rolling, size > limit {
            try? opened.close()
            roll(url)
            return openLog(url, rolling: false)
        }
        handle = opened
        sinceCheck = 0
        return opened
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }

    /// The current log becomes `<name>.previous.log`, replacing the one before.
    private func roll(_ url: URL) {
        close()
        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        size = 0
    }

    private static func inode(of url: URL) -> UInt64? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }
}
