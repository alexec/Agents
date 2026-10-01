import Foundation

/// The Mac's files pane is a tree: the top folder, and every folder opened in it.
/// Which of those are on screen, and which have nothing to show yet (#62).
///
/// A folder can be open before it has been read: the pane is drawn afresh with folders
/// still open from last time, or a file deep in the tree is revealed. Each such folder
/// is read once its parent's listing is in hand. Reading only the folders whose parents
/// were listed already left those to say "Reading…" for good.
public enum FileTree {
    /// A path as the tree keys it: no trailing slash, whichever way the URL was made.
    public static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The folders on screen: the top, and every open one whose parents are open and listed.
    public static func visibleFolders(root: URL, expanded: Set<String>,
                                      listings: [String: DirectoryListing]) -> [URL] {
        var folders = [root]
        func add(_ folder: URL) {
            for entry in listings[key(folder)]?.entries ?? []
            where entry.isDirectory && expanded.contains(key(entry.url)) {
                folders.append(entry.url)
                add(entry.url)
            }
        }
        add(root)
        return folders
    }

    /// The folders on screen with nothing to show: no listing, no sentence saying why
    /// there is none, and no read on its way.
    public static func unread(root: URL, expanded: Set<String>, listings: [String: DirectoryListing],
                              problems: Set<String> = [], reading: Set<String> = []) -> [URL] {
        visibleFolders(root: root, expanded: expanded, listings: listings).filter {
            let key = key($0)
            return listings[key] == nil && !problems.contains(key) && !reading.contains(key)
        }
    }
}
