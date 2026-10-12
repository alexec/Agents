#if canImport(CryptoKit)
import Foundation

/// A GitHub repository of skills as a marketplace (#687): every folder with a `SKILL.md`,
/// named by its folder. One tree read per repository, kept for ten minutes, so typing a
/// search spends no more of the API's hourly limit.
struct GitHubSkillsCatalog: Sendable {
    let github: GitHubSource
    let owner: String
    let repo: String
    let marketplace: String

    /// Every skill whose folder name holds the query, in the repository's order. An empty
    /// query lists them all: a repository is small enough to browse.
    func search(_ query: String) async throws -> [DaemonAPI.CatalogResult] {
        let want = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let folders = try await Self.cache.folders("\(owner)/\(repo)") {
            let head = try await github.head(owner: owner, repo: repo)
            let tree = try await github.tree(owner: owner, repo: repo, commit: head.commit)
            return Self.skillFolders(tree, repo: repo)
        }
        let known = KnownOwners.isKnown(owner)
        return folders
            .filter { want.isEmpty || $0.id.lowercased().contains(want) }
            .prefix(100)
            .map { DaemonAPI.CatalogResult(id: "\(owner)/\(repo)/\($0.id)", name: $0.id, owner: owner, repo: repo,
                                           skillID: $0.id, installs: 0, known: known, marketplace: marketplace,
                                           skillPath: $0.path) }
    }

    struct Folder: Equatable, Sendable {
        /// The folder's own name, or the repository's for a `SKILL.md` at the top.
        var id: String
        var path: String
    }

    /// Each `SKILL.md`'s folder, with only the ids a preview will take.
    static func skillFolders(_ tree: [GitHubSource.TreeEntry], repo: String = "") -> [Folder] {
        tree.filter { $0.type == "blob" && ($0.path == "SKILL.md" || $0.path.hasSuffix("/SKILL.md")) }
            .compactMap { entry in
                let parts = entry.path.split(separator: "/")
                let id = parts.count >= 2 ? String(parts[parts.count - 2]) : repo
                guard !id.isEmpty, id != ".", id != "..",
                      id.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return nil }
                return Folder(id: id, path: entry.path)
            }
    }

    static let cache = FolderCache()

    actor FolderCache {
        private var items: [String: (at: Date, folders: [Folder])] = [:]
        static let lifetime: TimeInterval = 10 * 60

        func folders(_ key: String, now: Date = Date(),
                     load: @Sendable () async throws -> [Folder]) async throws -> [Folder] {
            if let hit = items[key], now.timeIntervalSince(hit.at) < Self.lifetime { return hit.folders }
            let folders = try await load()
            items[key] = (now, folders)
            return folders
        }
    }
}
#endif
