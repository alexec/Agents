import Foundation

/// Where the daemon says what happened. Rolled, because it outlives every window and a
/// long-lived writer with no limit fills a disk eventually.
public final class DaemonLog: @unchecked Sendable {
    public static let shared = DaemonLog()

    private let lock = NSLock()
    private var url: URL?
    private let limit = 4 * 1024 * 1024

    public func setDestination(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        self.url = url
    }

    public func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard let url else { return }
        rollIfNeeded(url)
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private func rollIfNeeded(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard (size ?? 0) > limit else { return }
        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
}
