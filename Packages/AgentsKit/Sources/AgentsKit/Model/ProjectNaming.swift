import Foundation

/// What each project is called, given every project being listed.
///
/// A project is named by its own directory, which is short and right until two
/// directories share a name. Doing this over the whole set rather than one at a time is
/// what keeps the name minimal: `~/work/api` is "api" until `~/side/api` is listed too,
/// and then they are "work/api" and "side/api" and nothing else has grown.
public enum ProjectNaming {
    /// A display name for each folder, unique within the set it was given.
    public static func displayNames(for folders: [URL]) -> [URL: String] {
        var names: [URL: String] = [:]
        // How many trailing components each folder is currently showing.
        var depth: [URL: Int] = [:]
        for folder in folders {
            names[folder] = name(for: folder, depth: 1)
            depth[folder] = 1
        }

        // Extend leftwards, one component at a time, until nothing collides or nobody
        // has anything left to add. The loop is bounded by the longest path, so a
        // pathological set costs its own length and no more.
        var rounds = 0
        while rounds < 64 {
            rounds += 1
            let collisions = collidingFolders(in: names)
            if collisions.isEmpty { break }
            var grew = false
            for folder in collisions {
                let next = (depth[folder] ?? 1) + 1
                let candidate = name(for: folder, depth: next)
                // A folder that has run out of parents keeps what it has; the full path
                // is all there is, and two identical paths are the same project anyway.
                if candidate != names[folder] {
                    names[folder] = candidate
                    depth[folder] = next
                    grew = true
                }
            }
            if !grew { break }
        }
        return names
    }

    /// The folders whose current name is shared with another folder.
    private static func collidingFolders(in names: [URL: String]) -> [URL] {
        var byName: [String: [URL]] = [:]
        for (folder, name) in names { byName[name, default: []].append(folder) }
        return byName.values.filter { $0.count > 1 }.flatMap { $0 }
    }

    /// The last `depth` components of a folder, joined with `/`.
    private static func name(for folder: URL, depth: Int) -> String {
        let components = folder.standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return "/" }
        let taken = components.suffix(max(1, depth))
        return taken.joined(separator: "/")
    }
}
