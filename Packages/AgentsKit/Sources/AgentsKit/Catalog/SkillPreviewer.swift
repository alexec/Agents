#if canImport(CryptoKit)
import Foundation

/// A skill fetched at one commit into a folder the daemon owns, and nowhere an agent looks
/// (059, research R2 and R3). What Add later moves into place is exactly what was fetched
/// here and shown, and nothing is fetched again (FR-008).
struct StagedSkill: Sendable {
    var preview: DaemonAPI.SkillPreview
    /// `<root>/catalog-staging/<previewID>/<name>`.
    var folder: URL
    /// The skill's own `name`, which is the key the CLI records it under.
    var lockKey: String
    var createdAt: Date
}

/// The previews waiting to be added (data-model.md "SkillPreview"): at most eight, each
/// swept after half an hour, oldest first.
actor SkillStaging {
    let root: URL
    private var items: [UUID: StagedSkill] = [:]
    static let lifetime: TimeInterval = 30 * 60
    static let most = 8

    init(root: URL) { self.root = root }

    func folder(for id: UUID) -> URL { root.appending(path: id.uuidString) }

    func put(_ staged: StagedSkill, now: Date = Date()) {
        items[staged.preview.previewID] = staged
        sweep(now: now)
    }

    func get(_ id: UUID, now: Date = Date()) -> StagedSkill? {
        sweep(now: now)
        return items[id]
    }

    /// Take it for adding: it is used up whether the add succeeds or not.
    func take(_ id: UUID, now: Date = Date()) -> StagedSkill? {
        sweep(now: now)
        return items.removeValue(forKey: id)
    }

    /// Remove what is left of a taken preview once the add is done with it.
    func discard(_ id: UUID) { try? FileManager.default.removeItem(at: folder(for: id)) }

    private func sweep(now: Date) {
        for (id, item) in items where now.timeIntervalSince(item.createdAt) > Self.lifetime {
            items[id] = nil
            discard(id)
        }
        while items.count > Self.most, let oldest = items.values.min(by: { $0.createdAt < $1.createdAt }) {
            items[oldest.preview.previewID] = nil
            discard(oldest.preview.previewID)
        }
    }
}

struct SkillPreviewer: Sendable {
    let catalog: SkillsCatalog
    let github: GitHubSource

    static let maxBytes = 10 * 1024 * 1024
    static let maxFiles = 500

    /// Fetch `result` at its repository's current commit into `staging`. The destination
    /// state is left `.free`; the caller works it out for the destination asked about.
    func stage(_ result: DaemonAPI.CatalogResult, into staging: URL, id: UUID, now: Date = Date()) async throws -> StagedSkill {
        let owner = result.owner, repo = result.repo
        // The id goes into a URL path, like the owner and repo, which search already checked.
        guard SkillsCatalog.gitHubSource("\(owner)/\(repo)") != nil,
              !result.skillID.isEmpty, result.skillID != ".", result.skillID != "..",
              result.skillID.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
            throw DaemonAPI.CatalogError.cannotAdd([.notFoundInRepo])
        }
        let head = try await github.head(owner: owner, repo: repo)
        let work = staging.appending(path: ".work")
        defer { try? FileManager.default.removeItem(at: work) }

        // The file list: the API's tree, or the tarball's when the API is rate-limited.
        var tree: [GitHubSource.TreeEntry]
        var unpacked: URL?
        do {
            tree = try await github.tree(owner: owner, repo: repo, commit: head.commit)
        } catch is GitHubSource.RateLimited {
            do {
                let fallback = try await github.tarballTree(owner: owner, repo: repo, commit: head.commit, into: work)
                tree = fallback.tree
                unpacked = fallback.root
            } catch let error as DaemonAPI.CatalogError {
                if case .unreachable = error { throw DaemonAPI.CatalogError.rateLimited(retryAfter: nil) }
                throw error
            }
        }

        guard let skillMD = try await findSkill(result.skillID, in: tree, owner: owner, repo: repo, commit: head.commit,
                                                unpacked: unpacked) else {
            return empty(result, id: id, head: head, problems: [.notFoundInRepo], staging: staging, now: now)
        }
        let folderPath = String(skillMD.dropLast("SKILL.md".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = folderPath.isEmpty ? "" : folderPath + "/"

        var problems: [DaemonAPI.PreviewProblem] = []
        var skipped: [String] = []
        var wanted: [(relative: String, entry: GitHubSource.TreeEntry)] = []
        for entry in tree where entry.type == "blob" && entry.path.hasPrefix(prefix) {
            let relative = String(entry.path.dropFirst(prefix.count))
            if entry.mode == "120000" || !Self.isSafe(relative) { skipped.append(relative); continue }
            wanted.append((relative, entry))
        }
        let declared = wanted.reduce(0) { $0 + ($1.entry.size ?? 0) }
        if wanted.count > Self.maxFiles || declared > Self.maxBytes {
            return empty(result, id: id, head: head, problems: [.tooLarge(bytes: declared, files: wanted.count)],
                         staging: staging, now: now)
        }

        // The bytes: skills.sh's copy where each file's blob matches the commit's, GitHub's
        // own otherwise, and each file from GitHub checked too.
        let snapshot = unpacked == nil ? await catalog.snapshot(owner: owner, repo: repo, skillID: result.skillID) : nil
        let copies = Dictionary((snapshot?.files ?? []).map { ($0.path, Data($0.contents.utf8)) }, uniquingKeysWith: { a, _ in a })
        let name: String
        let stagedFolder: URL
        var files: [DaemonAPI.PreviewFile] = []
        var inMemory: [(path: String, data: Data)] = []
        var total = 0
        for (relative, entry) in wanted.sorted(by: { $0.relative < $1.relative }) {
            var data: Data
            var via: String
            if let root = unpacked {
                data = try Data(contentsOf: root.appending(path: entry.path))
                via = "tarball"
            } else if let copy = copies[relative], SkillHashes.blobSHA(copy) == entry.sha {
                data = copy
                via = "snapshot"
            } else {
                data = try await github.raw(owner: owner, repo: repo, commit: head.commit, path: entry.path)
                via = "raw"
                guard SkillHashes.blobSHA(data) == entry.sha else {
                    throw DaemonAPI.CatalogError.unreachable(host: github.endpoints.raw.host ?? "raw.githubusercontent.com")
                }
            }
            total += data.count
            let runnable = entry.mode == "100755" || relative.hasPrefix("scripts/") || data.starts(with: Data("#!".utf8))
            files.append(.init(path: relative, bytes: data.count, runnable: runnable, via: via))
            inMemory.append((relative, data))
        }
        if total > Self.maxBytes {
            return empty(result, id: id, head: head, problems: [.tooLarge(bytes: total, files: files.count)],
                         staging: staging, now: now)
        }
        let markdown = inMemory.first(where: { $0.path == "SKILL.md" }).map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        let front = SkillFile(text: markdown)
        guard let skillName = front.name, let description = front.description else {
            return empty(result, id: id, head: head, problems: [.noSkillFile], staging: staging, now: now,
                         markdown: markdown, files: files)
        }
        name = SkillFile.folderName(skillName)
        stagedFolder = staging.appending(path: name)
        try? FileManager.default.removeItem(at: stagedFolder)
        for (relative, data) in inMemory {
            let url = stagedFolder.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            let mode = wanted.first(where: { $0.relative == relative })?.entry.mode
            try FileManager.default.setAttributes([.posixPermissions: mode == "100755" ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        if !skipped.isEmpty { problems.append(.skipped(skipped)) }

        // The CLI records GitHub's own tree SHA for the folder; the staged copy's is the same
        // unless something was skipped, and is the fallback when the tree came from a tarball.
        let apiTree = tree.first(where: { $0.type == "tree" && $0.path == folderPath && !$0.sha.isEmpty })?.sha
        let treeSHA = try apiTree ?? SkillHashes.treeSHA(folder: stagedFolder)
        let committedAt = await github.commitDate(owner: owner, repo: repo, commit: head.commit, folder: folderPath)
        let preview = DaemonAPI.SkillPreview(
            previewID: id, result: result, name: name, description: description, skillPath: skillMD,
            commit: head.commit, committedAt: committedAt, treeSHA: treeSHA,
            computedHash: SkillHashes.computedHash(files: inMemory), files: files, skillMarkdown: markdown,
            totalBytes: total, problems: problems, destinationState: .free)
        return StagedSkill(preview: preview, folder: stagedFolder, lockKey: skillName, createdAt: now)
    }

    /// Which `SKILL.md` is the skill: a folder named like the id first, then one whose own
    /// `name` makes the same slug (the CLI's rule, research R2), then a lone one at the top.
    private func findSkill(_ skillID: String, in tree: [GitHubSource.TreeEntry], owner: String, repo: String,
                           commit: String, unpacked: URL?) async throws -> String? {
        let candidates = tree.filter { $0.type == "blob" && ($0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md")) }
            .map(\.path)
        let want = SkillFile.slug(skillID)
        if let byFolder = candidates.first(where: {
            let parts = $0.split(separator: "/")
            return parts.count >= 2 && SkillFile.slug(String(parts[parts.count - 2])) == want
        }) { return byFolder }
        for path in candidates.prefix(20) {
            let data: Data
            if let root = unpacked {
                data = (try? Data(contentsOf: root.appending(path: path))) ?? Data()
            } else {
                data = (try? await github.raw(owner: owner, repo: repo, commit: commit, path: path)) ?? Data()
            }
            if let name = SkillFile(text: String(decoding: data, as: UTF8.self)).name, SkillFile.slug(name) == want {
                return path
            }
        }
        return candidates == ["SKILL.md"] ? "SKILL.md" : nil
    }

    /// A relative path that stays inside the skill's folder.
    static func isSafe(_ relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\") else { return false }
        return !relative.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    private func empty(_ result: DaemonAPI.CatalogResult, id: UUID, head: GitHubSource.Head,
                       problems: [DaemonAPI.PreviewProblem], staging: URL, now: Date,
                       markdown: String = "", files: [DaemonAPI.PreviewFile] = []) -> StagedSkill {
        let preview = DaemonAPI.SkillPreview(
            previewID: id, result: result, name: SkillFile.folderName(result.skillID), description: "", skillPath: "",
            commit: head.commit, committedAt: nil, treeSHA: "", computedHash: "", files: files,
            skillMarkdown: markdown, totalBytes: files.reduce(0) { $0 + $1.bytes }, problems: problems,
            destinationState: .free)
        return StagedSkill(preview: preview, folder: staging.appending(path: "none"), lockKey: result.skillID, createdAt: now)
    }
}
#endif
