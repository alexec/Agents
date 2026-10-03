import Foundation
import AgentsKitCore

/// A file that says what the person approved, read so that one it cannot read approves
/// nothing (#169).
///
/// The approval stores (workflows, plugins, MCP servers) used to read a file they could
/// not decode as "approval has not begun", which approves everything, and then saved
/// that empty value over it. Here a missing file is still the first start, but a file
/// that is there and cannot be read means approval began and nothing is approved: every
/// workflow, plugin and server waits for the person.
///
/// The unreadable file is left exactly as it is. Writes nobody asked for (a tick, a fire)
/// skip it; only the person's own act (Approve, an add or remove from a sheet) replaces
/// it, and then a copy is kept beside it as `<name>.corrupt-<date>` first.
enum ApprovalFile {
    enum Read<Records> {
        case missing
        case read(Records)
        case unreadable
    }

    /// What `url` holds. An unreadable one is logged once per version of the file.
    static func read<Records: Decodable>(_ type: Records.Type, at url: URL) -> Read<Records> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if let data = try? Data(contentsOf: url),
           let records = try? StoreCoding.decoder.decode(Records.self, from: data) {
            return .read(records)
        }
        UnreadableLog.shared.note(url)
        return .unreadable
    }

    /// What the page says where approvals show, while `url` cannot be read.
    static func note(_ url: URL) -> String {
        "\(url.lastPathComponent) could not be read, so nothing is approved until you approve it again."
    }

    /// Write `data` to `url`. While the file there could not be read, only the person's
    /// own act writes (`replacing`), and the file is copied aside first; any other write
    /// leaves it alone.
    static func write(_ data: Data, to url: URL, overUnreadable: Bool, replacing: Bool) throws {
        if overUnreadable {
            guard replacing else { return }
            try keepCopy(of: url)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Copy `url` to `<name>.corrupt-<date>` beside it, so the only copy of what was
    /// approved is not the one about to be replaced.
    static func keepCopy(of url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        if !FileManager.default.fileExists(atPath: copy.path) {
            try FileManager.default.copyItem(at: url, to: copy)
        }
        DaemonLog.shared.write("store: \(url.lastPathComponent) replaced at the person's approval; the unreadable one is kept as \(copy.lastPathComponent)")
    }
}

/// Says once that a file could not be read, not on every read of it: the stores are read
/// every tick. A file that changes and still cannot be read is said again.
final class UnreadableLog: @unchecked Sendable {
    static let shared = UnreadableLog()
    private let lock = NSLock()
    private var said: Set<String> = []

    /// Whether this was the first time this version of the file was said.
    @discardableResult
    func note(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? Int) ?? -1
        let key = "\(url.path)|\(modified)|\(size)"
        let first = lock.withLock { said.insert(key).inserted }
        guard first else { return false }
        DaemonLog.shared.write("store: \(url.lastPathComponent) could not be read; nothing it approved is approved, and it is left as it is")
        return true
    }
}
