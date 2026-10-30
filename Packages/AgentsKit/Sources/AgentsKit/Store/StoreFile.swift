import Foundation
import AgentsKitCore

/// The one rule every whole-file store keeps (#171, #205).
///
/// - A missing file is the store's empty state, as it always was.
/// - A file that reads and does not decode is moved aside as `<name>.corrupt-<time>`,
///   said once in the log, and remembered for this run so that the page that shows the
///   store can say so; the store carries on empty. It is never read as empty and then
///   written over, which is how devices, modes and the day's spend used to be lost.
/// - A file that does not read at all (not allowed, too many files open, an I/O error)
///   is tried once more. If it still does not read it is left where it is and the store
///   is held: it reads as empty and every write to it is refused for the rest of the
///   run (#205). A good `devices.json` is never moved aside for a passing error.
/// - A file outside the daemon's root (a folder's `pins.json`) is never moved inside the person's tree: a copy goes under the root
///   (`outside`), the file stays, and writes to it are refused until it reads again.
/// - At most `StoreCoding.asidesKept` copies of one file are kept.
/// - Every write is whole: a temporary file, synced, then renamed into place.
///
/// The approval stores keep their own reading (`ApprovalFile`, #169): there an
/// unreadable file approves nothing and stays where it is until the person approves.
enum StoreFile {
    enum Read<Value> {
        case missing
        case read(Value)
        case unreadable(Unreadable)
    }

    enum Unreadable: Equatable {
        /// It did not decode, and is now at this name, or still in place when even the
        /// move failed (`nil`), and then nothing may be written over it.
        case setAside(URL?)
        /// It did not decode and is a folder's: a copy is at this name (nil when even
        /// that failed); the file is where it was, and held until it reads.
        case copied(URL?)
        /// It did not read, twice; it is where it was, and held for the run.
        case held
    }

    /// A write refused because the file is held (#205).
    struct Held: Error, LocalizedError, Equatable {
        var url: URL
        var untilRestart: Bool
        var errorDescription: String? {
            untilRestart
                ? "\(url.lastPathComponent) could not be read, so nothing is written to it until Agents restarts; it is kept as it was."
                : "\(url.lastPathComponent) could not be read, so nothing is written to it until it reads again; it is kept as it was."
        }
    }

    /// How a file's bytes are read. A test stands in for the disk here to make a read
    /// fail once, or every time.
    @TaskLocal static var reader: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }

    /// The bytes at `url`, tried twice. Nil with the error when neither read.
    private static func bytes(_ url: URL) -> Result<Data, Error> {
        do { return .success(try reader(url)) } catch {
            DaemonLog.shared.write("store: \(url.lastPathComponent) did not read (\(error)); trying once more")
            do { return .success(try reader(url)) } catch { return .failure(error) }
        }
    }

    /// What `url` holds, by `decode`. See the type for what happens to one that does not.
    /// `outside` is the daemon's root, given for a file that is not under it.
    static func read<Value>(at url: URL, meaning: String, outside root: URL? = nil,
                            decode: (Data) throws -> Value) -> Read<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            StoreHolds.shared.released(url, unlessForRun: true)
            return .missing
        }
        let data: Data
        switch bytes(url) {
        case .success(let read): data = read
        case .failure(let error):
            guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
            hold(url, forRun: true, because: "\(error.localizedDescription)", meaning: meaning)
            return .unreadable(.held)
        }
        if let value = try? decode(data) {
            StoreHolds.shared.released(url, unlessForRun: true)
            return .read(value)
        }
        if let root {
            return .unreadable(.copied(copyAside(url, under: root, meaning: meaning)))
        }
        return .unreadable(.setAside(setAside(url, meaning: meaning)))
    }

    /// What `url` holds, by `decoder`.
    static func read<Value: Decodable>(_ type: Value.Type, at url: URL,
                                       decoder: JSONDecoder = StoreCoding.decoder,
                                       meaning: String, outside root: URL? = nil) -> Read<Value> {
        read(at: url, meaning: meaning, outside: root) { try decoder.decode(Value.self, from: $0) }
    }

    /// `read`, with the empty state for a missing or unreadable file.
    static func load<Value: Decodable>(_ type: Value.Type, at url: URL, empty: Value,
                                       decoder: JSONDecoder = StoreCoding.decoder,
                                       meaning: String, outside root: URL? = nil) -> Value {
        if case .read(let value) = read(type, at: url, decoder: decoder, meaning: meaning, outside: root) { return value }
        return empty
    }

    /// Move an unreadable `url` aside and log it. `meaning` finishes the log
    /// line: what the store carries on as ("starting with no devices").
    @discardableResult
    static func setAside(_ url: URL, meaning: String) -> URL? {
        let aside = StoreCoding.setAside(url)
        if let aside {
            DaemonLog.shared.write("store: \(url.lastPathComponent) could not be read; set aside as \(aside.lastPathComponent), \(meaning)")
        } else if FileManager.default.fileExists(atPath: url.path) {
            DaemonLog.shared.write("store: \(url.lastPathComponent) could not be read nor moved aside; left as it is, \(meaning)")
            hold(url, forRun: true, because: "it could not be moved aside", meaning: meaning)
        }
        return aside
    }

    /// Copy a folder's unreadable `url` under the daemon's `root`, once for the bytes
    /// it has, and hold it until it reads.
    @discardableResult
    static func copyAside(_ url: URL, under root: URL, meaning: String) -> URL? {
        let folder = StoreCoding.asideFolder(for: url, under: root)
        let data = try? reader(url)
        if let last = StoreCoding.asides(of: url, in: folder).last, let data, (try? Data(contentsOf: last)) == data {
            StoreHolds.shared.hold(url, forRun: false)
            return last
        }
        let aside = StoreCoding.setAside(url, in: folder, copy: true)
        StoreHolds.shared.hold(url, forRun: false)
        if let aside {
            DaemonLog.shared.write("store: \(url.path) could not be read; a copy is kept as \(aside.path), and nothing is written to it until it reads again; \(meaning)")
        } else {
            DaemonLog.shared.write("store: \(url.path) could not be read nor copied; nothing is written to it until it reads again; \(meaning)")
        }
        return aside
    }

    private static func hold(_ url: URL, forRun: Bool, because why: String, meaning: String) {
        guard StoreHolds.shared.hold(url, forRun: forRun) else { return }
        DaemonLog.shared.write("store: \(url.lastPathComponent) could not be read (\(why)); left where it is and held: nothing is written to it this run, \(meaning)")
    }

    /// Write `data` to `url` whole and synced, unless it is held.
    static func write(_ data: Data, to url: URL, permissions: Int? = nil) throws {
        if let untilRestart = StoreHolds.shared.isHeld(url) { throw Held(url: url, untilRestart: untilRestart) }
        try StoreCoding.writeAtomically(data, to: url, permissions: permissions)
    }
}

/// The files no write may touch in this run (#205): one that would not read is held for
/// the run; a folder's that would not decode, until it reads again.
final class StoreHolds: @unchecked Sendable {
    static let shared = StoreHolds()
    private let lock = NSLock()
    private var held: [String: Bool] = [:]

    /// Answers whether it was newly held.
    @discardableResult
    func hold(_ url: URL, forRun: Bool) -> Bool {
        let key = url.standardizedFileURL.path
        return lock.withLock {
            let before = held[key]
            held[key] = forRun || before == true
            return before == nil
        }
    }

    /// A read that worked lets a folder's file be written again.
    func released(_ url: URL, unlessForRun: Bool) {
        let key = url.standardizedFileURL.path
        lock.withLock {
            guard let forRun = held[key], !(forRun && unlessForRun) else { return }
            held[key] = nil
        }
    }

    /// Nil when it may be written; otherwise whether it is held until a restart.
    func isHeld(_ url: URL) -> Bool? {
        lock.withLock { held[url.standardizedFileURL.path] }
    }
}
