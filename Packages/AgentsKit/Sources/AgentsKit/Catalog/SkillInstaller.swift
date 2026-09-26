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

    /// Thrown from `afterRename` in a test to stand for the daemon dying at that moment: the
    /// add stops where it is, with nothing undone, as a killed process would leave it.
    struct Stop: Error {}

    // MARK: The journal

    /// An add under way, written before anything moves and removed once the lock is written.
    /// A daemon that died in between finds it at its next start and undoes the add
    /// (`recover`), so the destination is never left half-changed (SC-003). Without it, a
    /// folder moved into place with no lock entry would look like the person's own and would
    /// never be touched again.
    struct Pending: Codable, Equatable {
        var lock: String
        var personal: Bool
        var key: String
        var hash: String
        var target: String
        var trashed: String?
    }

    var journal: URL { sidecar.deletingLastPathComponent().appending(path: "catalog-pending.json") }

    /// Undo an add a dead daemon left unfinished; nothing to do if the lock was written.
    /// Returns what was undone, for the log.
    @discardableResult
    static func recover(journal: URL) -> String? {
        guard let data = try? Data(contentsOf: journal),
              let pending = try? JSONDecoder().decode(Pending.self, from: data) else { return nil }
        defer { try? FileManager.default.removeItem(at: journal) }
        let lock = try? SkillLock.load(pending.personal ? .personal : .project, at: URL(filePath: pending.lock))
        if lock?.entry(pending.key)?.recordedHash == pending.hash { return nil }
        let target = URL(filePath: pending.target)
        try? FileManager.default.removeItem(at: target)
        if let trashed = pending.trashed { try? FileManager.default.moveItem(at: URL(filePath: trashed), to: target) }
        return "undid an unfinished add of \(target.lastPathComponent)"
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

        // 0. The journal, before anything moves, so a daemon that dies from here on is undone
        //    at its next start.
        let hash = place.lockKind == .personal ? preview.treeSHA : preview.computedHash
        var pending = Pending(lock: place.lock.path, personal: place.lockKind == .personal, key: staged.lockKey,
                              hash: hash, target: target.path, trashed: nil)
        do {
            try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(pending).write(to: journal, options: .atomic)
        } catch {
            throw DaemonAPI.CatalogError.failed("could not note the add before starting it")
        }
        // 1. The old folder, if any, to the Trash, remembered (here and in the journal) so it
        //    can come back.
        var trashed: URL?
        if Self.exists(target) {
            do { trashed = try trash(target, place: place, now: now) } catch {
                try? fm.removeItem(at: journal)
                throw DaemonAPI.CatalogError.failed("could not move the old copy to the Trash")
            }
            pending.trashed = trashed?.path
            try? JSONEncoder().encode(pending).write(to: journal, options: .atomic)
        }
        // 2. The staged folder into place.
        do {
            try fm.moveItem(at: staged.folder, to: target)
        } catch {
            if let trashed { try? fm.moveItem(at: trashed, to: target) }
            try? fm.removeItem(at: journal)
            throw DaemonAPI.CatalogError.failed("could not move the skill into \(place.skills.path)")
        }
        // 3. The lock. A failure here takes the new folder back out and puts the old one back.
        do {
            try afterRename?()
            if let old = place.managedEntry(folderName: preview.name, in: lock), old.key != staged.lockKey {
                lock.remove(name: old.key)
            }
            lock.upsert(name: staged.lockKey, source: preview.result.source, skillPath: preview.skillPath, hash: hash, now: now)
            try lock.write()
            try? fm.removeItem(at: journal)
        } catch is Stop {
            throw DaemonAPI.CatalogError.failed("stopped")
        } catch {
            try? fm.removeItem(at: target)
            if let trashed { try? fm.moveItem(at: trashed, to: target) }
            try? fm.removeItem(at: journal)
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

    /// Every skill in the destination's folder, a lock's or the person's own, by name
    /// (frame D). A folder with no SKILL.md is not a skill and is left out; a missing
    /// folder is an empty list, not an error.
    func list(at place: SkillPlace) -> [DaemonAPI.ListedSkill] {
        let managed = managed(at: place)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: place.skills.path)) ?? []).sorted()
        var skills: [DaemonAPI.ListedSkill] = []
        for name in names where !name.hasPrefix(".") {
            let folder = place.skills.appending(path: name)
            guard let text = try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8) else { continue }
            skills.append(.init(name: name, description: SkillFile(text: text).description, folder: folder.path,
                                managed: managed[name]))
        }
        return skills
    }

    /// The folder no longer hashes to what its lock recorded (research R6).
    func edited(_ folder: URL, entry: SkillLock.Entry, kind: SkillLock.Kind) -> Bool {
        guard let recorded = entry.recordedHash, !recorded.isEmpty else { return false }
        let now = kind == .personal ? try? SkillHashes.treeSHA(folder: folder) : try? SkillHashes.computedHash(folder: folder)
        return now != nil && now != recorded
    }

    // MARK: Remove

    /// Take out a skill a lock names: its folder to the Trash, then its lock entry and its
    /// sidecar record. A folder no lock names is refused and left as it is (FR-020, FR-021).
    /// If the lock cannot be written, the folder comes back.
    func remove(_ name: String, at place: SkillPlace, now: Date = Date()) throws -> URL {
        var lock = try SkillLock.load(place.lockKind, at: place.lock)
        guard let (key, _) = place.managedEntry(folderName: name, in: lock) else {
            throw DaemonAPI.CatalogError.notManaged(name: name)
        }
        let folder = place.skills.appending(path: name)
        var trashed: URL?
        if Self.exists(folder) { trashed = try trash(folder, place: place, now: now) }
        do {
            lock.remove(name: key)
            try lock.write()
        } catch {
            if let trashed { try? FileManager.default.moveItem(at: trashed, to: folder) }
            throw DaemonAPI.CatalogError.failed("could not write \(place.lock.lastPathComponent)")
        }
        var side = CatalogSidecar.load(from: sidecar)
        side.skills[CatalogSidecar.key(place.destination, name: name)] = nil
        try? side.save(to: sidecar) { _ in true }
        return trashed ?? folder
    }

    // MARK: What an update changes

    /// Files added, changed and removed going from the installed folder to a staged one,
    /// by path and content.
    static func changes(from installed: URL, to staged: URL) -> DaemonAPI.SkillChanges {
        let before = files(in: installed), after = files(in: staged)
        let added = after.keys.filter { before[$0] == nil }.sorted()
        let removed = before.keys.filter { after[$0] == nil }.sorted()
        let changed = after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.sorted()
        return .init(added: added, changed: changed, removed: removed)
    }

    /// Relative path → git blob id, for every plain file under `folder`.
    private static func files(in folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        let base = folder.standardizedFileURL.path
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url) else { continue }
            out[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = SkillHashes.blobSHA(data)
        }
        return out
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
