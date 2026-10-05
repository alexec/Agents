import Foundation
import AgentsKitCore

/// Where a project's Dashboard is kept (074): its tiles and their trends in the project,
/// and the host's own bookkeeping on the host.
///
/// - `<project>/.agents/dashboard/<id>.json`: one file per tile, committed with the
///   project. Written whole (temporary file, then rename), and not at all when the bytes
///   would be the same (FR-015, FR-016). Always the project folder, never a worktree's
///   copy: the caller hands the project folder, never an agent's `cwd` (FR-014).
/// - `<project>/.agents/dashboard/history/<id>.jsonl`: a number tile's points, one a
///   line, so its trend travels with the project (#127). Folded on every write to each
///   hour's last point for 7 days and each day's last to 90, a value equal to the last
///   kept is never written, and the file is not touched when its bytes would be the same.
/// - `<root>/dashboards/<key>/state.json`: when each tile was made and last set, the
///   hash of the host's last write (to tell an outside change), keeper changes, removal
///   notes and each agent's recent sets (FR-019).
/// - `<root>/dashboards/<key>/points/<id>.jsonl`: where points were kept before #127,
///   moved into the project the first time they are read.
///
/// Called only from inside the daemon's actor, which is what makes one write at a time
/// per project. Plain Foundation, so the Linux daemon has it too.
final class DashboardStore: @unchecked Sendable {
    let root: URL
    /// The daemon's root, where a project file that does not read is copied (#205).
    let storeRoot: URL
    private var states: [URL: DashboardState] = [:]
    private var pointCache: [String: [TilePoint]] = [:]
    /// Each cached history file's modification date as read or written here, so the
    /// watch hearing this store's own write does not throw the points away (#173).
    private var pointStamps: [String: Date] = [:]
    /// Each project's tile files as last read, with the stamp of their folder then (#216).
    /// Every Dashboard read and every wake asked for all of them; now one stat answers
    /// whether the copy is still good, and the watch drops it when a tile file changes
    /// in place (`forgetTiles`).
    private var tileCache: [URL: (stamp: Date?, tiles: [Found])] = [:]
    /// How many tile files have been read, for the tests and the measure (#216).
    private(set) var tileReads = 0
    /// Each project's history in bytes, kept up as points are written (#216), and the
    /// history folder's stamp as this store last left it.
    private var historyTotals: [URL: (stamp: Date?, bytes: Int)] = [:]

    init(locations: StoreLocations) {
        root = locations.root.appendingPathComponent("dashboards", isDirectory: true)
        storeRoot = locations.root
    }

    // MARK: The project's files

    static func tilesFolder(_ project: URL) -> URL {
        project.appendingPathComponent(".agents/dashboard", isDirectory: true)
    }

    static func tileFile(_ project: URL, _ id: String) -> URL {
        tilesFolder(project).appendingPathComponent("\(id).json")
    }

    /// One tile file as found: its id, what it holds or why it can't be read, and the
    /// hash of its bytes.
    struct Found {
        var id: String
        var tile: TileFile?
        var problem: String?
        var hash: String
    }

    /// Every tile file in the project's `.agents/dashboard/`. A worktree's copy is never
    /// read: this is handed the project folder.
    func readTiles(_ project: URL) -> [Found] {
        let folder = Self.tilesFolder(project)
        let stamp = Self.modified(folder)
        if let held = tileCache[project], held.stamp == stamp { return held.tiles }
        let tiles = tileIDs(project).compactMap { read(project, $0) }
        tileCache[project] = (stamp, tiles)
        return tiles
    }

    /// The tiles' ids, by their files' names alone: one listing, nothing read (#216).
    func tileIDs(_ project: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.tilesFolder(project).path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let id = String(name.dropLast(5))
            return TileLimits.isValidID(id) ? id : nil
        }
    }

    /// A tile file changed where this store did not write it (the watch saw it): every
    /// tile is read again when next asked.
    func forgetTiles(_ project: URL) {
        tileCache.removeValue(forKey: project)
    }

    /// What this store just wrote or removed, put straight into the held copy so the
    /// next read does not go back to every file for one.
    private func noteTile(_ found: Found?, id: String, in project: URL) {
        guard var held = tileCache[project] else { return }
        held.tiles.removeAll { $0.id == id }
        if let found {
            held.tiles.append(found)
            held.tiles.sort { $0.id < $1.id }
        }
        held.stamp = Self.modified(Self.tilesFolder(project))
        tileCache[project] = held
    }

    func read(_ project: URL, _ id: String) -> Found? {
        tileReads += 1
        guard let data = try? Data(contentsOf: Self.tileFile(project, id)) else { return nil }
        return Self.found(id, data)
    }

    private static func found(_ id: String, _ data: Data) -> Found {
        let digest = Self.hash(data)
        if data.count > TileLimits.fileBytes {
            return Found(id: id, tile: nil, problem: "The file is over \(TileLimits.fileBytes / 1024) KB.", hash: digest)
        }
        do {
            return Found(id: id, tile: try TileFile.read(data), problem: nil, hash: digest)
        } catch {
            return Found(id: id, tile: nil, problem: words(error), hash: digest)
        }
    }

    /// Write a tile whole. Returns the hash of what is in the file now, and whether it
    /// had to be written: identical bytes are left alone.
    @discardableResult
    func write(_ tile: TileFile, id: String, in project: URL) throws -> (hash: String, written: Bool) {
        let data = try tile.fileData()
        let url = Self.tileFile(project, id)
        if let old = try? Data(contentsOf: url), old == data { return (Self.hash(data), false) }
        try StoreFile.write(data, to: url)
        noteTile(Self.found(id, data), id: id, in: project)
        return (Self.hash(data), true)
    }

    func deleteFile(_ id: String, in project: URL) throws {
        let url = Self.tileFile(project, id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        noteTile(nil, id: id, in: project)
    }

    // MARK: The order (#147)

    static func orderFile(_ project: URL) -> URL {
        tilesFolder(project).appendingPathComponent(DashboardOrder.fileName)
    }

    /// Nil when nobody has moved a tile. One that does not read (a merge's conflict
    /// markers, say) is left where it is, mid-merge or not, with a copy under the
    /// daemon's root, and no move writes over it until it reads again (#171, #205); the
    /// tiles show in the order they were made, and the Dashboard says so (`notes`).
    func readOrder(_ project: URL) -> DashboardOrder? {
        if case .read(let order) = StoreFile.read(DashboardOrder.self, at: Self.orderFile(project), decoder: JSONDecoder(),
                                                  meaning: "the tiles show in the order they were made",
                                                  outside: storeRoot) {
            return order
        }
        return nil
    }

    /// What the Dashboard says about its files set aside in this run, or nil.
    func notes(_ project: URL) -> String? {
        let notes = SetAsideNotes.shared.notes(under: Self.tilesFolder(project))
            + SetAsideNotes.shared.notes(under: folder(for: project))
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// Write the order whole, or remove the file when it lists nothing. Unchanged bytes
    /// are left alone, as a tile's are.
    func writeOrder(_ order: DashboardOrder, in project: URL) throws {
        let url = Self.orderFile(project)
        _ = readOrder(project)  // one fixed by hand since it was last read is writable again
        guard !order.isEmpty else {
            try StoreFile.requireWritable(url)
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(order)
        data.append(0x0A)
        if let old = try? Data(contentsOf: url), old == data { return }
        try StoreFile.write(data, to: url)
        // The order is not a tile: the tiles held stay good across it.
        noteTile(nil, id: DashboardOrder.fileName, in: project)
    }

    // MARK: The host's state

    func folder(for project: URL) -> URL {
        root.appendingPathComponent(Self.key(project), isDirectory: true)
    }

    func state(_ project: URL) -> DashboardState {
        if let known = states[project] { return known }
        let url = folder(for: project).appendingPathComponent("state.json")
        let loaded = StoreFile.load(DashboardState.self, at: url, empty: DashboardState(folder: project.path),
                                    meaning: "every tile's made and set times start again")
        states[project] = loaded
        return loaded
    }

    /// Kept in memory whatever happens; answers what went wrong writing it, for the
    /// agent's reply, or nil. Never swallowed (#171).
    @discardableResult
    func save(_ state: DashboardState, for project: URL) -> String? {
        states[project] = state
        do {
            try StoreFile.write(try StoreCoding.encoder.encode(state),
                                to: folder(for: project).appendingPathComponent("state.json"))
            return nil
        } catch {
            DaemonLog.shared.write("dashboard: state.json for \(project.path) could not be written: \(error)")
            return "This host's note of when tiles were set could not be written: \(error.localizedDescription)"
        }
    }

    // MARK: Points

    static func historyFolder(_ project: URL) -> URL {
        tilesFolder(project).appendingPathComponent("history", isDirectory: true)
    }

    private func pointsFile(_ project: URL, _ id: String) -> URL {
        Self.historyFolder(project).appendingPathComponent("\(id).jsonl")
    }

    /// Where this host kept a tile's points before #127.
    private func hostPointsFile(_ project: URL, _ id: String) -> URL {
        folder(for: project).appendingPathComponent("points/\(id).jsonl")
    }

    func points(_ project: URL, _ id: String) -> [TilePoint] {
        let key = Self.key(project) + "/" + id
        if let known = pointCache[key] { return known }
        var out = readPoints(pointsFile(project, id))
        // Points this host kept before #127, folded into the project's once.
        let legacy = hostPointsFile(project, id)
        if FileManager.default.fileExists(atPath: legacy.path) {
            let merged = (readPoints(legacy) + out).sorted { $0.at < $1.at }
            out = Self.compacted(merged, now: Date())
            if (try? writePoints(out, for: id, in: project)) != nil {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
        pointCache[key] = out
        pointStamps[key] = Self.modified(pointsFile(project, id))
        return out
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// A line that does not read costs that line, but never silently (#171): the whole
    /// file is first copied under the daemon's root, once for those bytes and never into
    /// the project (#205), before the next write drops it. A torn last line, a crash
    /// mid-append, is only dropped. A file that does not read at all is held, so no
    /// point is written over it (`StoreFile`).
    private func readPoints(_ url: URL) -> [TilePoint] {
        let read = StoreFile.read(at: url, meaning: "the tile's trend starts again", outside: storeRoot) { data in
            let lines = data.split(separator: UInt8(ascii: "\n"))
            var unreadable = 0
            let points = lines.enumerated().compactMap { index, line -> TilePoint? in
                guard let point = try? JSONDecoder().decode(PointLine.self, from: Data(line)) else {
                    if index != lines.count - 1 { unreadable += 1 }
                    return nil
                }
                return TilePoint(at: Date(timeIntervalSince1970: point.t), value: point.v)
            }
            return (points, unreadable)
        }
        guard case .read(let (points, unreadable)) = read else { return [] }
        if unreadable > 0 {
            StoreFile.keepPartCopy(url, under: storeRoot, what: "\(unreadable) lines")
        }
        return points
    }

    /// Record a point (#127). Nothing is written for a value equal to the last kept: the
    /// trend already says it. Otherwise the history is folded with it and written only
    /// if its bytes changed, so a second set in the same hour replaces that hour's point.
    /// Returns whether a point was added.
    @discardableResult
    func record(_ value: Double, at: Date, for id: String, in project: URL) throws -> Bool {
        var all = points(project, id)
        if all.last?.value == value { return false }
        all.append(TilePoint(at: at, value: value))
        try rewritePoints(Self.compacted(all, now: at), for: id, in: project)
        return true
    }

    /// The cache holds what was meant, the file what could be written; a failure is the
    /// caller's to say.
    func rewritePoints(_ all: [TilePoint], for id: String, in project: URL) throws {
        let key = Self.key(project) + "/" + id
        pointCache[key] = all
        try writePoints(all, for: id, in: project)
        pointStamps[key] = Self.modified(pointsFile(project, id))
    }

    /// The file for `all`, whole, and only when its bytes change; none for no points.
    private func writePoints(_ all: [TilePoint], for id: String, in project: URL) throws {
        let url = pointsFile(project, id)
        guard !all.isEmpty else {
            try StoreFile.requireWritable(url)
            if FileManager.default.fileExists(atPath: url.path) {
                let size = Self.size(url)
                try FileManager.default.removeItem(at: url)
                noteHistory(project, change: -size)
            }
            return
        }
        var data = Data()
        for point in all { data.append(Self.line(point)) }
        let old = try? Data(contentsOf: url)
        if let old, old == data { return }
        try StoreFile.write(data, to: url)
        noteHistory(project, change: data.count - (old?.count ?? 0))
    }

    /// Keep the running total up with a write or removal of this store's own.
    private func noteHistory(_ project: URL, change: Int) {
        guard var held = historyTotals[project] else { return }
        held.bytes = max(0, held.bytes + change)
        held.stamp = Self.modified(Self.historyFolder(project))
        historyTotals[project] = held
    }

    func deletePoints(_ id: String, in project: URL) throws {
        pointCache.removeValue(forKey: Self.key(project) + "/" + id)
        for url in [pointsFile(project, id), hostPointsFile(project, id)]
        where FileManager.default.fileExists(atPath: url.path) {
            let size = Self.size(url)
            try FileManager.default.removeItem(at: url)
            if url == pointsFile(project, id) { noteHistory(project, change: -size) }
        }
    }

    /// Read the points again whose history file changed outside this store, by a pull
    /// or by hand. A file as this store last left it keeps its points: that is the watch
    /// hearing our own write (#173).
    func forgetPoints(_ project: URL) {
        let prefix = Self.key(project) + "/"
        var outside = false
        for key in pointCache.keys where key.hasPrefix(prefix) {
            let id = String(key.dropFirst(prefix.count))
            guard let stamp = pointStamps[key], stamp == Self.modified(pointsFile(project, id)) else {
                pointCache.removeValue(forKey: key)
                pointStamps.removeValue(forKey: key)
                outside = true
                continue
            }
        }
        // The total too, when a file changed or came or went that this store did not write.
        if outside || historyTotals[project]?.stamp != Self.modified(Self.historyFolder(project)) {
            historyTotals.removeValue(forKey: project)
        }
    }

    /// The project's history, in bytes (FR-021). Added up once, then kept up by this
    /// store's own writes (#216); a change from outside makes it add up again.
    func historyBytes(_ project: URL) -> Int {
        let folder = Self.historyFolder(project)
        let stamp = Self.modified(folder)
        if let held = historyTotals[project], held.stamp == stamp { return held.bytes }
        // Only the histories: a `.corrupt-` copy an earlier build left here is not one.
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        let bytes = names.reduce(0) { $0 + Self.size(folder.appendingPathComponent($1)) }
        historyTotals[project] = (stamp, bytes)
        return bytes
    }

    private static func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Whether the project has any history to fold, here or from before #127.
    func hasHistory(_ project: URL) -> Bool {
        FileManager.default.fileExists(atPath: Self.historyFolder(project).path)
            || FileManager.default.fileExists(atPath: folder(for: project).appendingPathComponent("points").path)
    }

    /// Fold old points (FR-020, #127), on the housekeeping tick, so a tile nobody sets
    /// still loses what has aged out. Never on a read.
    func compact(_ project: URL, now: Date) {
        var ids: Set<String> = []
        for folder in [Self.historyFolder(project), folder(for: project).appendingPathComponent("points", isDirectory: true)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".jsonl") { ids.insert(String(name.dropLast(6))) }
        }
        for id in ids.sorted() where TileLimits.isValidID(id) {
            let all = points(project, id)
            let folded = Self.compacted(all, now: now)
            if folded != all {
                do {
                    try rewritePoints(folded, for: id, in: project)
                } catch {
                    DaemonLog.shared.write("dashboard: \(id)'s history could not be folded in \(project.path): \(error)")
                }
            }
        }
    }

    /// Each hour's last point for 7 days, each day's last to 90 days, then nothing
    /// (Alex, 2026-10-03, #127); and a run of equal values kept as its first point, the
    /// moment the value became what it is.
    static func compacted(_ points: [TilePoint], now: Date) -> [TilePoint] {
        var out: [TilePoint] = []
        var lastBucket: (Int, Int)?
        for point in points {
            let age = now.timeIntervalSince(point.at)
            if age > 90 * 86_400 { continue }
            let seconds = Int(point.at.timeIntervalSince1970.rounded(.down))
            let bucket = age > 7 * 86_400 ? (1, seconds / 86_400) : (0, seconds / 3600)
            if let lastBucket, lastBucket == bucket, !out.isEmpty {
                out[out.count - 1] = point
            } else {
                out.append(point)
            }
            lastBucket = bucket
        }
        var kept: [TilePoint] = []
        for point in out where kept.last?.value != point.value { kept.append(point) }
        return kept
    }

    /// At most `limit` points from `since` on, evenly picked, the last always kept.
    static func downsampled(_ points: [TilePoint], since: Date, limit: Int) -> [TilePoint] {
        let recent = points.filter { $0.at >= since }
        guard recent.count > limit, limit > 1 else { return recent }
        let step = Double(recent.count - 1) / Double(limit - 1)
        return (0..<limit).map { recent[Int((Double($0) * step).rounded())] }
    }

    // MARK: A project going

    /// Removing a project deletes what this host kept about it; its files, history
    /// included since #127, are left alone (FR-022).
    func deleteHistory(_ project: URL) {
        states.removeValue(forKey: project)
        tileCache.removeValue(forKey: project)
        historyTotals.removeValue(forKey: project)
        pointCache = pointCache.filter { !$0.key.hasPrefix(Self.key(project) + "/") }
        try? FileManager.default.removeItem(at: folder(for: project))
    }

    /// Moving a project carries its history to the new folder's key (FR-022). What was
    /// already at the new key is replaced only once the move can be made, so a failure
    /// leaves both where they were (#171).
    func moveHistory(from old: URL, to new: URL) {
        let source = folder(for: old), target = folder(for: new)
        guard FileManager.default.fileExists(atPath: source.path), source != target else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: target)
            }
        } catch {
            DaemonLog.shared.write("dashboard: the history for \(old.path) could not move to \(new.path): \(error)")
            return
        }
        states.removeValue(forKey: old)
        states.removeValue(forKey: new)
        pointCache = pointCache.filter { !$0.key.hasPrefix(Self.key(old) + "/") }
        var moved = state(new)
        moved.folder = new.path
        save(moved, for: new)
    }

    // MARK: Inside

    private struct PointLine: Codable {
        var t: Double
        var v: Double
    }

    /// Keys sorted, so the same points are always the same bytes: the file is in the
    /// project now (#127), and a line that reorders itself is a diff about nothing.
    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func line(_ point: TilePoint) -> Data {
        var data = (try? lineEncoder.encode(PointLine(t: point.at.timeIntervalSince1970.rounded(), v: point.value))) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The host's folder for a project: 16 hex characters of a hash of its path.
    static func key(_ project: URL) -> String {
        hash(Data(Project.standardize(project).path.utf8))
    }

    /// FNV-1a, 64 bits, as hex. For telling bytes apart, not for secrets; the same on
    /// the Mac and Linux, which CryptoKit is not.
    static func hash(_ data: Data) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    static func words(_ error: any Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "It has no \(key.stringValue)."
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? "It is not a tile's JSON." : "Its \(path) is not what a tile holds."
        case DecodingError.dataCorrupted: return "It is not valid JSON."
        default: return "It could not be read."
        }
    }
}

/// What the host keeps about a project's Dashboard (`state.json`).
struct DashboardState: Codable, Sendable, Hashable {
    var folder: String
    var tiles: [String: TileRecord] = [:]
    /// Who removed which tile and when, kept 30 days only to tell its keeper (FR-028).
    var removals: [String: Removal] = [:]
    /// Each agent's sets in the last hour, by agent id (FR-009).
    var sets: [String: [Date]] = [:]
    /// The one-off agent Update now last started, for a project with no dashboard
    /// workflow (#146). Its agent is nil while the runtime is still starting.
    var updater: Updater?

    struct Updater: Codable, Sendable, Hashable {
        var agentID: UUID?
        var startedAt: Date
    }

    struct TileRecord: Codable, Sendable, Hashable {
        var made: Date
        var set: Date?
        /// The hash of the bytes this host last wrote.
        var hash: String?
        var keeperChanges: [KeeperChange] = []
    }

    struct Removal: Codable, Sendable, Hashable {
        var at: Date
        var by: String
    }
}
