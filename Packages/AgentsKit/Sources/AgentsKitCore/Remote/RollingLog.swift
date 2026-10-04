import Foundation

/// A device's own log, kept in a file that can be read off it after the fact (#175).
///
/// The moment worth reading is the one nobody was watching: a Remote stuck until it is
/// killed takes its console with it. Each line is stamped, and the file is kept small:
/// past `limit` bytes it becomes `<name>.1` (the one before that is dropped) and a new
/// file is begun, so the two together never pass twice the limit.
///
/// Lines are written in order on a queue of the log's own, never on the caller's thread.
public final class RollingLog: @unchecked Sendable {
    public let url: URL
    public let limit: Int
    private let queue: DispatchQueue
    private let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public init(url: URL, limit: Int = 256 * 1024) {
        self.url = url
        self.limit = max(1_024, limit)
        queue = DispatchQueue(label: "com.alexecollins.agents.log.\(url.lastPathComponent)")
    }

    /// The file before this one.
    public var previous: URL {
        url.deletingPathExtension().appendingPathExtension("1." + (url.pathExtension.isEmpty ? "log" : url.pathExtension))
    }

    public func append(_ line: String, at date: Date = Date()) {
        let stamped = Data((date.formatted(stamp) + " " + line + "\n").utf8)
        queue.async { [self] in write(stamped) }
    }

    /// Waits until every line appended so far is on disk.
    public func flush() {
        queue.sync {}
    }

    private func write(_ data: Data) {
        let files = FileManager.default
        let size = ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, size + data.count > limit {
            try? files.removeItem(at: previous)
            try? files.moveItem(at: url, to: previous)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
