import AgentsKitCore
import Foundation

/// The projects a host arrives with (#429): asked once by the control plane, when the
/// host is added, and never again, so a project the person removes stays removed.
extension DaemonCore {
    /// Adds every folder `found` names that is not a project already, and says how many.
    public func detectProjects(_ detection: ProjectDetection) async -> Int {
        guard detection.enabled else { return 0 }
        let known = Set(projectRecords().keys)
        var added = 0
        for folder in Self.found(detection.paths) where !known.contains(Project.standardize(folder)) {
            if (try? await addProject(folder)) != nil { added += 1 }
        }
        DaemonLog.shared.write("projects: found \(added) on this host under \(detection.paths.joined(separator: ", "))")
        return added
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
