import Foundation

/// What a checkout's git state looks like on disk, read without running git (#207): its
/// HEAD, and the size and time of its index and its HEAD's log. A commit, a checkout, a
/// reset or a `git add` moves one of them; so an answer worked out from git can be given
/// again while the stamp is the same. Edits to files git tracks do not move it (nothing
/// here refreshes the index), which is why every answer kept by it also has a lifetime.
struct GitStamp: Sendable, Equatable {
    var parts: [String]

    /// The stamp of the checkout at `root`, with the files named in `also` (paths below
    /// the repository's common `.git`) beside it; nil when `root` has no `.git`.
    static func of(_ root: URL, commonDir: URL? = nil, also: [String] = []) -> GitStamp? {
        guard let gitDir = gitDirectory(of: root) else { return nil }
        let common = commonDir ?? gitDir
        var parts = [(try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8)) ?? "-"]
        parts.append(stat(gitDir.appending(path: "index")))
        parts.append(stat(gitDir.appending(path: "logs/HEAD")))
        for path in also { parts.append(stat(common.appending(path: path))) }
        return GitStamp(parts: parts)
    }

    /// `.git` itself, or where a linked worktree's `.git` file points.
    static func gitDirectory(of root: URL) -> URL? {
        let dotGit = root.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(filePath: path, directoryHint: .isDirectory)
            : root.appending(path: path, directoryHint: .isDirectory).standardizedFileURL
    }

    private static func stat(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "-" }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let time = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)@\(time)"
    }
}
