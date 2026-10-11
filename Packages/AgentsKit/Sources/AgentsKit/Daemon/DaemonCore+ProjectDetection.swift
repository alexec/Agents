import AgentsKitCore
import Foundation

/// The projects a person may add on a host (#429, #656): suggested, never added by
/// themselves. The window lists them, unticked, and adds the ones the person ticks.
extension DaemonCore {
    /// Every repository found under `paths`, then each of `folders` as it stands, each once.
    public func findProjects(_ request: DaemonAPI.ProjectsFindRequest,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [DaemonAPI.FoundFolder] {
        let known = Set(projectRecords().keys)
        var seen: Set<String> = []
        var answer: [DaemonAPI.FoundFolder] = []
        for folder in Self.found(request.paths, home: home) where seen.insert(folder.path(percentEncoded: false)).inserted {
            answer.append(.init(folder: folder, exists: true, isRepository: true, isProject: known.contains(folder)))
        }
        for typed in request.folders {
            let trimmed = typed.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let folder = Project.standardize(Self.expand(trimmed, home: home))
            let exists = Self.isDirectory(folder)
            answer.append(.init(typed: trimmed, folder: folder, exists: exists,
                                isRepository: exists && FileManager.default.fileExists(
                                    atPath: folder.appending(path: ".git").path(percentEncoded: false)),
                                isProject: known.contains(folder)))
        }
        return answer
    }

    /// The immediate folders of each path that have `.git` in them, a folder or a file
    /// (a worktree's), each once and in order. `~` is this host's home. Hidden folders are
    /// left out: `~/.oh-my-zsh` is a checkout, not a project.
    static func found(_ paths: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let files = FileManager.default
        var seen: Set<String> = []
        var found: [URL] = []
        for path in paths {
            let parent = expand(path, home: home)
            guard let children = try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles]) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard isDirectory(child),
                      files.fileExists(atPath: child.appending(path: ".git").path(percentEncoded: false)) else { continue }
                let folder = Project.standardize(child)
                if seen.insert(folder.path(percentEncoded: false)).inserted { found.append(folder) }
            }
        }
        return found
    }

    /// `~` and `~/x` against `home`; anything else as a path.
    static func expand(_ path: String, home: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home.appending(path: String(trimmed.dropFirst(2)), directoryHint: .isDirectory) }
        return URL(filePath: trimmed, directoryHint: .isDirectory)
    }
}
