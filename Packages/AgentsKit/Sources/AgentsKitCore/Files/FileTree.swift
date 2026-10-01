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

/// Where a files pane is to be when it shows its folder again (#66): the file last
/// open is marked, and brought into view unless it is where the person left it.
///
/// A file opened from a row of the tree on screen is in view already: the tree is kept
/// as it was under the file, scroll and all, and Back finds it there. One opened from
/// anywhere else — the chat, a card, an agent's `show_file` — or a tree drawn afresh
/// is scrolled to it, once its row has been read.
public struct FileTreePlace: Equatable, Sendable {
    /// The file last open, by `FileTree.key`. Kept after Back, so its row stays marked.
    public private(set) var marked: String?
    /// The row still to be brought into view, once it is among the rows.
    public private(set) var toScroll: String?

    public init() {}

    /// A file is open. `fromRow` is true when the person chose it from the tree on screen.
    public mutating func opened(_ url: URL, fromRow: Bool) {
        let key = FileTree.key(url)
        marked = key
        toScroll = fromRow ? nil : key
    }

    /// The tree is drawn new, at the top: whatever is marked has to be found again.
    public mutating func drawnAfresh() {
        toScroll = marked
    }

    /// The row to scroll to now, given the rows the tree has, by key. Nil while it is
    /// not among them (its folder not read yet); once it is, it is scrolled to once.
    public mutating func scroll(among rows: some Sequence<String>) -> String? {
        guard let toScroll, rows.contains(toScroll) else { return nil }
        self.toScroll = nil
        return toScroll
    }

    /// The pane is somewhere else now (the agent moved): nothing to mark or find.
    public mutating func forget() {
        marked = nil
        toScroll = nil
    }
}
