import Foundation
import AgentsKitCore

/// The one rule every whole-file store keeps (#171).
///
/// - A missing file is the store's empty state, as it always was.
/// - A file that is there and cannot be read or decoded is moved aside as
///   `<name>.corrupt-<time>`, said once in the log, and remembered for this run so that
///   the page that shows the store can say so; the store carries on empty. It is never
///   read as empty and then written over, which is how devices, modes and the day's
///   spend used to be lost.
/// - Every write is whole: a temporary file, synced, then renamed into place.
///
/// The approval stores keep their own reading (`ApprovalFile`, #169): there an
/// unreadable file approves nothing and stays where it is until the person approves.
enum StoreFile {
    enum Read<Value> {
        case missing
        case read(Value)
        /// It could not be read; it is now at this name, or still in place when even the
        /// move failed (`nil`), and then nothing may be written over it.
        case setAside(URL?)
    }

    /// What `url` holds, by `decoder`. One that does not read is set aside.
    static func read<Value: Decodable>(_ type: Value.Type, at url: URL,
                                       decoder: JSONDecoder = StoreCoding.decoder,
                                       meaning: String) -> Read<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if let data = try? Data(contentsOf: url),
           let value = try? decoder.decode(Value.self, from: data) {
            return .read(value)
        }
        return .setAside(setAside(url, meaning: meaning))
    }

    /// `read`, with the empty state for a missing or set-aside file.
    static func load<Value: Decodable>(_ type: Value.Type, at url: URL, empty: Value,
                                       decoder: JSONDecoder = StoreCoding.decoder,
                                       meaning: String) -> Value {
        if case .read(let value) = read(type, at: url, decoder: decoder, meaning: meaning) { return value }
        return empty
    }

    /// A list read one element at a time (`Lossy`): one bad entry costs that entry, not
    /// the list. When any is dropped, the whole file is first copied aside and the
    /// readable ones written back, so what was dropped is kept and the file is clean; a
    /// file that is not a list at all is set aside.
    static func loadList<Element: Codable>(_ type: Element.Type, at url: URL,
                                           encoder: JSONEncoder = StoreCoding.encoder,
                                           decoder: JSONDecoder = StoreCoding.decoder,
                                           meaning: String) -> [Element] {
        switch read([Lossy<Element>].self, at: url, decoder: decoder, meaning: meaning) {
        case .missing, .setAside: return []
        case .read(let entries):
            let kept = entries.compactMap(\.value)
            guard kept.count < entries.count else { return kept }
            let aside = StoreCoding.asideName(for: url)
            do {
                try FileManager.default.copyItem(at: url, to: aside)
                try write(try encoder.encode(kept), to: url)
                DaemonLog.shared.write("store: \(entries.count - kept.count) of \(entries.count) entries in \(url.lastPathComponent) could not be read; the whole file is kept as \(aside.lastPathComponent)")
                SetAsideNotes.shared.add(url, aside: aside, partly: true)
            } catch {
                DaemonLog.shared.write("store: \(entries.count - kept.count) entries in \(url.lastPathComponent) could not be read, and it could not be copied aside: \(error)")
            }
            return kept
        }
    }

    /// Move an unreadable `url` aside, log it, and keep the note. `meaning` finishes the
    /// log line: what the store carries on as ("starting with no devices").
    @discardableResult
    static func setAside(_ url: URL, meaning: String) -> URL? {
        let aside = StoreCoding.setAside(url)
        if let aside {
            DaemonLog.shared.write("store: \(url.lastPathComponent) could not be read; set aside as \(aside.lastPathComponent), \(meaning)")
            SetAsideNotes.shared.add(url, aside: aside)
        } else if FileManager.default.fileExists(atPath: url.path) {
            DaemonLog.shared.write("store: \(url.lastPathComponent) could not be read nor moved aside; left as it is, \(meaning)")
        }
        return aside
    }

    /// Write `data` to `url` whole and synced.
    static func write(_ data: Data, to url: URL) throws {
        try StoreCoding.writeAtomically(data, to: url)
    }
}

/// The files set aside in this run, so a page that shows a store can say its file was
/// set aside. Kept in memory only: the log keeps the lasting record, and the
/// `.corrupt-` file itself stays beside the store until the person removes it.
final class SetAsideNotes: @unchecked Sendable {
    static let shared = SetAsideNotes()
    private let lock = NSLock()
    private var notes: [String: String] = [:]

    func add(_ url: URL, aside: URL, partly: Bool = false) {
        let sentence = partly
            ? "Some of \(url.lastPathComponent) could not be read; the whole file was kept as \(aside.lastPathComponent)."
            : "\(url.lastPathComponent) could not be read, so it was set aside as \(aside.lastPathComponent) and started afresh."
        lock.withLock { notes[url.standardizedFileURL.path] = sentence }
    }

    /// What to say where the store at `url` shows, or nil when it was read.
    func note(for url: URL) -> String? {
        lock.withLock { notes[url.standardizedFileURL.path] }
    }

    /// Every note for files under `folder`, oldest path first.
    func notes(under folder: URL) -> [String] {
        let prefix = folder.standardizedFileURL.path + "/"
        return lock.withLock { notes.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.map(\.value) }
    }
}
