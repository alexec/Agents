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
///
/// Once approval has begun, a marker beside the file (`.<name>.began`) says so (#205).
/// Then a file that decodes with no `approvalsBegan` (`{}`), or no file at all (the
/// person deleting the unreadable one to recover), is unreadable too, not "never
/// began", which would approve everything at the next start.
enum ApprovalFile {
    enum Read<Records> {
        case missing
        case read(Records)
        /// With what decoded, when it did (a file that lost `approvalsBegan`): its
        /// bookkeeping is salvaged by the store, never its approvals.
        case unreadable(Records?)
    }

    static func marker(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).began")
    }

    /// What `url` holds. An unreadable one is logged once per version of the file.
    static func read<Records: Decodable>(_ type: Records.Type, at url: URL,
                                         began: (Records) -> Date?) -> Read<Records> {
        let marked = FileManager.default.fileExists(atPath: marker(for: url).path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard marked else { return .missing }
            UnreadableLog.shared.note(url, gone: true)
            return .unreadable(nil)
        }
        let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: url))
        guard let records = data.flatMap({ try? StoreCoding.decoder.decode(Records.self, from: $0) }) else {
            UnreadableLog.shared.note(url)
            return .unreadable(nil)
        }
        if began(records) == nil {
            guard !marked else {
                UnreadableLog.shared.note(url)
                return .unreadable(records)
            }
            return .read(records)
        }
        if !marked { markBegan(url) }
        return .read(records)
    }

    /// What the page says where approvals show, while `url` cannot be read.
    static func note(_ url: URL) -> String {
        "\(url.lastPathComponent) could not be read, so nothing is approved until you approve it again."
    }

    /// Write `data` to `url`. While the file there could not be read, only the person's
    /// own act writes (`replacing`), and the file is copied aside first; any other write
    /// leaves it alone. `began` marks that approval has begun, for good.
    static func write(_ data: Data, to url: URL, overUnreadable: Bool, replacing: Bool, began: Bool) throws {
        if overUnreadable {
            guard replacing else { return }
            try keepCopy(of: url)
        }
        try StoreCoding.writeAtomically(data, to: url)
        if began { markBegan(url) }
    }

    private static func markBegan(_ url: URL) {
        let marker = marker(for: url)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? StoreCoding.writeAtomically(Data("Approval began here; see #205.\n".utf8), to: marker)
    }

    /// Copy `url` to `<name>.corrupt-<date>` beside it, so the only copy of what was
    /// approved is not the one about to be replaced. At most `StoreCoding.asidesKept`.
    static func keepCopy(of url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // The same name every store sets an unreadable file aside under (#171).
        guard let copy = StoreCoding.setAside(url, copy: true) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
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
    func note(_ url: URL, gone: Bool = false) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? Int) ?? -1
        let key = "\(url.path)|\(modified)|\(size)"
        let first = lock.withLock { said.insert(key).inserted }
        guard first else { return false }
        DaemonLog.shared.write(gone
            ? "store: \(url.lastPathComponent) is gone after approval began; nothing is approved until the person approves"
            : "store: \(url.lastPathComponent) could not be read; nothing it approved is approved, and it is left as it is")
        return true
    }
}
