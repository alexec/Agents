#if canImport(CryptoKit)
import Foundation

/// Putting a staged skill in place, and taking one out (059, contracts/catalog-methods.md).
///
/// In full or not at all (FR-009): the old folder, if the skill was there before, goes to
/// the Trash first; the staged folder is renamed into place; the lock is written; and if a
/// step fails, what was done is undone, so the destination is as it was before or exactly as
/// previewed and never anything in between (SC-003).
///
/// A folder no lock names is never written, moved or removed (FR-013, SC-004).
struct SkillInstaller: Sendable {
    /// The daemon's `catalog-skills.json`.
    let sidecar: URL
    /// Called between the rename and the lock write, for the test that an add interrupted
    /// there leaves nothing behind. Nil everywhere but that test.
    var afterRename: (@Sendable () throws -> Void)?

    init(sidecar: URL, afterRename: (@Sendable () throws -> Void)? = nil) {
        self.sidecar = sidecar
        self.afterRename = afterRename
    }

    // MARK: What is there

    func state(of preview: DaemonAPI.SkillPreview, at place: SkillPlace) -> DaemonAPI.DestinationState {
        let lock: SkillLock
        do { lock = try SkillLock.load(place.lockKind, at: place.lock) } catch let e as DaemonAPI.CatalogError {
            return .unavailable(e)
        } catch { return .unavailable(.failed(String(describing: error))) }
        if let (_, entry) = place.managedEntry(folderName: preview.name, in: lock) {
            let same = entry.source.lowercased() == preview.result.source.lowercased()
                && (entry.skillPath == nil || entry.skillPath == preview.skillPath)
            guard same else { return .managedOther(source: entry.source) }
            let now = place.lockKind == .personal ? preview.treeSHA : preview.computedHash
            return .sameSkill(update: entry.recordedHash != now)
        }
        let target = place.skills.appending(path: preview.name)
        if Self.exists(target) { return .unmanaged(path: target.path) }
        return .free
    }

    // MARK: Add

    func add(_ staged: StagedSkill, to place: SkillPlace, replace: Bool, now: Date = Date()) throws -> DaemonAPI.ManagedSkill {
        let preview = staged.preview
        guard preview.canAdd else { throw DaemonAPI.CatalogError.cannotAdd(preview.problems.filter(\.blocksAdding)) }
        switch state(of: preview, at: place) {
        case .free:
            if replace { throw DaemonAPI.CatalogError.replaceMismatch }
        case .sameSkill(let update):
            if update && !replace { throw DaemonAPI.CatalogError.replaceMismatch }
        case .managedOther:
            if !replace { throw DaemonAPI.CatalogError.replaceMismatch }
        case .unmanaged(let path):
            throw DaemonAPI.CatalogError.unmanaged(path: path)
        case .unavailable(let error):
            throw error
        }

        var lock = try SkillLock.load(place.lockKind, at: place.lock)
        let fm = FileManager.default
        let target = place.skills.appending(path: preview.name)
        try fm.createDirectory(at: place.skills, withIntermediateDirectories: true)

        // 1. The old folder, if any, to the Trash, remembered so it can come back.
        var trashed: URL?
        if Self.exists(target) { trashed = try trash(target, place: place, now: now) }
        // 2. The staged folder into place.
        do {
            try fm.moveItem(at: staged.folder, to: target)
        } catch {
            if let trashed { try? fm.moveItem(at: trashed, to: target) }
            throw DaemonAPI.CatalogError.failed("could not move the skill into \(place.skills.path)")
        }
        // 3. The lock. A failure here takes the new folder back out and puts the old one back.
        do {
            try afterRename?()
            if let old = place.managedEntry(folderName: preview.name, in: lock), old.key != staged.lockKey {
                lock.remove(name: old.key)
            }
            let hash = place.lockKind == .personal ? preview.treeSHA : preview.computedHash
            lock.upsert(name: staged.lockKey, source: preview.result.source, skillPath: preview.skillPath, hash: hash, now: now)
            try lock.write()
        } catch {
            try? fm.removeItem(at: target)
            if let trashed { try? fm.moveItem(at: trashed, to: target) }
            if let e = error as? DaemonAPI.CatalogError { throw e }
            throw DaemonAPI.CatalogError.failed("could not write \(place.lock.lastPathComponent)")
        }
        // 4. The project's Claude link, if the project has none (research R7).
        if let folder = place.folder { Self.linkClaudeSkills(in: folder) }
        // 5. The sidecar: worth having, not worth failing for.
        var side = CatalogSidecar.load(from: sidecar)
        side.skills[CatalogSidecar.key(place.destination, name: preview.name)] = .init(
            commit: preview.commit, committedAt: preview.committedAt, treeSHA: preview.treeSHA,
            catalogue: "skills.sh", addedAt: now)
        try? side.save(to: sidecar) { _ in true }

        return DaemonAPI.ManagedSkill(
            destination: place.destination, name: preview.name, source: preview.result.source,
            skillPath: preview.skillPath, recordedHash: place.lockKind == .personal ? preview.treeSHA : preview.computedHash,
            commit: preview.commit, committedAt: preview.committedAt, catalogue: "skills.sh", edited: false, update: .current)
    }

    // MARK: Reading what is managed

    /// Every skill at `place` a lock names, keyed by folder name.
    func managed(at place: SkillPlace) -> [String: DaemonAPI.ManagedSkill] {
        guard let lock = try? SkillLock.load(place.lockKind, at: place.lock) else { return [:] }
        let side = CatalogSidecar.load(from: sidecar)
        var out: [String: DaemonAPI.ManagedSkill] = [:]
        for key in lock.names {
            guard let entry = lock.entry(key), entry.sourceType == "github" else { continue }
            let name = SkillFile.folderName(key)
            let folder = place.skills.appending(path: name)
            guard Self.exists(folder) else { continue }
            let record = side.skills[CatalogSidecar.key(place.destination, name: name)]
            out[name] = DaemonAPI.ManagedSkill(
                destination: place.destination, name: name, source: entry.source, skillPath: entry.skillPath,
                recordedHash: entry.recordedHash, commit: record?.commit, committedAt: record?.committedAt,
                catalogue: record?.catalogue, edited: edited(folder, entry: entry, kind: place.lockKind), update: .unknown)
        }
        return out
    }

    /// The folder no longer hashes to what its lock recorded (research R6).
    func edited(_ folder: URL, entry: SkillLock.Entry, kind: SkillLock.Kind) -> Bool {
        guard let recorded = entry.recordedHash, !recorded.isEmpty else { return false }
        let now = kind == .personal ? try? SkillHashes.treeSHA(folder: folder) : try? SkillHashes.computedHash(folder: folder)
        return now != nil && now != recorded
    }

    // MARK: Helpers

    /// To the person's Trash for the ordinary daemon, to `<root>/trash` for anything else.
    func trash(_ url: URL, place: SkillPlace, now: Date) throws -> URL {
        let fm = FileManager.default
        if let folder = place.trash {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Int(now.timeIntervalSince1970 * 1000)
            let to = folder.appending(path: "\(url.lastPathComponent)-\(stamp)-\(UUID().uuidString.prefix(4))")
            try fm.moveItem(at: url, to: to)
            return to
        }
        var result: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }

    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// `.claude/skills -> ../.agents/skills`, only where nothing of that name is there yet.
    static func linkClaudeSkills(in folder: URL) {
        let link = folder.appending(path: ".claude/skills")
        guard !exists(link) else { return }
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../\(DotAgents.folder)/skills")
    }
}
#endif
