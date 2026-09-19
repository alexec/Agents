import Foundation

/// Everywhere one agent may read and write.
///
/// The one piece of this feature where a mistake writes to the wrong place on
/// somebody's disk, so it is pure, small, refuses by default, and has its own tests.
/// Every served file request and every terminal's working directory goes through it.
public struct FolderScope: Hashable, Sendable {
    public var folders: [URL]

    public init(folders: [URL]) {
        self.folders = folders
    }

    /// Whether this path is inside one of the folders, with symlinks followed.
    ///
    /// A path that does not exist yet is judged by its nearest parent that does, so an
    /// agent can create a file but not create one somewhere it was never given.
    public func allows(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let target = URL(filePath: path)
        guard target.path.hasPrefix("/") else { return false }
        guard let resolved = Self.resolve(target) else { return false }
        return folders.contains { folder in
            guard let base = Self.resolve(folder) else { return false }
            return Self.contains(base, resolved)
        }
    }

    /// Why a path was refused, in words the agent and the user can both read.
    public func refusal(for path: String) -> String {
        let names = folders.map(\.path).joined(separator: ", ")
        return "Outside this agent's folders (\(names))"
    }

    /// The real location of a path, following symlinks, working up to the nearest
    /// parent that exists when the path itself does not.
    private static func resolve(_ url: URL) -> URL? {
        let manager = FileManager.default
        var current = url.standardizedFileURL
        var missing: [String] = []
        while !manager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent().standardizedFileURL
            // `/` is its own parent: a path that climbs past the root is not a path.
            guard parent.path != current.path else { return nil }
            missing.append(current.lastPathComponent)
            current = parent
        }
        var resolved = current.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved = resolved.appending(path: component)
        }
        return resolved.standardizedFileURL
    }

    private static func contains(_ base: URL, _ target: URL) -> Bool {
        if base.path == target.path { return true }
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return target.path.hasPrefix(basePath)
    }
}
