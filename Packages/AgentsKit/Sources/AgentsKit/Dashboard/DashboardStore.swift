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
    private var states: [URL: DashboardState] = [:]
    private var pointCache: [String: [TilePoint]] = [:]

    init(locations: StoreLocations) {
        root = locations.root.appendingPathComponent("dashboards", isDirectory: true)
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
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let id = String(name.dropLast(5))
            guard TileLimits.isValidID(id) else { return nil }
            return read(project, id)
        }
    }

    func read(_ project: URL, _ id: String) -> Found? {
        guard let data = try? Data(contentsOf: Self.tileFile(project, id)) else { return nil }
        let hash = Self.hash(data)
        if data.count > TileLimits.fileBytes {
            return Found(id: id, tile: nil, problem: "The file is over \(TileLimits.fileBytes / 1024) KB.", hash: hash)
        }
        do {
            return Found(id: id, tile: try TileFile.read(data), problem: nil, hash: hash)
        } catch {
            return Found(id: id, tile: nil, problem: Self.words(error), hash: hash)
        }
    }

    /// Write a tile whole. Returns the hash of what is in the file now, and whether it
    /// had to be written: identical bytes are left alone.
    @discardableResult
    func write(_ tile: TileFile, id: String, in project: URL) throws -> (hash: String, written: Bool) {
        let data = try tile.fileData()
        let url = Self.tileFile(project, id)
        if let old = try? Data(contentsOf: url), old == data { return (Self.hash(data), false) }
        try FileManager.default.createDirectory(at: Self.tilesFolder(project), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return (Self.hash(data), true)
    }

    func deleteFile(_ id: String, in project: URL) {
        try? FileManager.default.removeItem(at: Self.tileFile(project, id))
    }

    // MARK: The host's state

    func folder(for project: URL) -> URL {
        root.appendingPathComponent(Self.key(project), isDirectory: true)
    }

    func state(_ project: URL) -> DashboardState {
        if let known = states[project] { return known }
        let url = folder(for: project).appendingPathComponent("state.json")
        let loaded = (try? Data(contentsOf: url)).flatMap { try? StoreCoding.decoder.decode(DashboardState.self, from: $0) }
            ?? DashboardState(folder: project.path)
        states[project] = loaded
        return loaded
    }

    func save(_ state: DashboardState, for project: URL) {
        states[project] = state
        let folder = folder(for: project)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? StoreCoding.encoder.encode(state) {
            try? data.write(to: folder.appendingPathComponent("state.json"), options: .atomic)
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
        var out = Self.readPoints(pointsFile(project, id))
        // Points this host kept before #127, folded into the project's once.
        let legacy = hostPointsFile(project, id)
        if FileManager.default.fileExists(atPath: legacy.path) {
            let merged = (Self.readPoints(legacy) + out).sorted { $0.at < $1.at }
            out = Self.compacted(merged, now: Date())
            if (try? writePoints(out, for: id, in: project)) != nil {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
        pointCache[key] = out
        return out
    }

    private static func readPoints(_ url: URL) -> [TilePoint] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            (try? JSONDecoder().decode(PointLine.self, from: Data(line)))
                .map { TilePoint(at: Date(timeIntervalSince1970: $0.t), value: $0.v) }
        }
    }

    /// Record a point (#127). Nothing is written for a value equal to the last kept: the
    /// trend already says it. Otherwise the history is folded with it and written only
    /// if its bytes changed, so a second set in the same hour replaces that hour's point.
    /// Returns whether a point was added.
    @discardableResult
    func record(_ value: Double, at: Date, for id: String, in project: URL) -> Bool {
        var all = points(project, id)
        if all.last?.value == value { return false }
        all.append(TilePoint(at: at, value: value))
        rewritePoints(Self.compacted(all, now: at), for: id, in: project)
        return true
    }

    func rewritePoints(_ all: [TilePoint], for id: String, in project: URL) {
        pointCache[Self.key(project) + "/" + id] = all
        try? writePoints(all, for: id, in: project)
    }

    /// The file for `all`, whole, and only when its bytes change; none for no points.
    private func writePoints(_ all: [TilePoint], for id: String, in project: URL) throws {
        let url = pointsFile(project, id)
        guard !all.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        var data = Data()
        for point in all { data.append(Self.line(point)) }
        if let old = try? Data(contentsOf: url), old == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func deletePoints(_ id: String, in project: URL) {
        pointCache.removeValue(forKey: Self.key(project) + "/" + id)
        try? FileManager.default.removeItem(at: pointsFile(project, id))
        try? FileManager.default.removeItem(at: hostPointsFile(project, id))
    }

    /// Read every point again: the history files changed outside the app, by a pull or
    /// by hand.
    func forgetPoints(_ project: URL) {
        pointCache = pointCache.filter { !$0.key.hasPrefix(Self.key(project) + "/") }
    }

    /// The project's history, in bytes (FR-021).
    func historyBytes(_ project: URL) -> Int {
        let folder = Self.historyFolder(project)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.reduce(0) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size]) as? Int
            return total + (size ?? 0)
        }
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
            if folded != all { rewritePoints(folded, for: id, in: project) }
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
        pointCache = pointCache.filter { !$0.key.hasPrefix(Self.key(project) + "/") }
        try? FileManager.default.removeItem(at: folder(for: project))
    }

    /// Moving a project carries its history to the new folder's key (FR-022).
    func moveHistory(from old: URL, to new: URL) {
        let source = folder(for: old), target = folder(for: new)
        guard FileManager.default.fileExists(atPath: source.path), source != target else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: source, to: target)
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
