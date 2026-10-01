import Foundation

/// The Changes pane's list as a tree, the way GitHub's "Files changed" draws one (#63).
///
/// Folders nest, folders come before files, both by name as the Files pane sorts them, and
/// a folder holding nothing but one folder folds into a single line (`App/Sources`). Every
/// folder carries the total of what changed under it.
public enum ChangeTree {
    public indirect enum Node: Hashable, Sendable, Identifiable {
        /// `name` is what the row says, folded (`App/Sources`); `key` is the whole path
        /// from the top, which is what opening and closing remember.
        case folder(name: String, key: String, children: [Node], totals: Totals)
        case file(ChangedFile)

        public var id: String {
            switch self {
            case .folder(_, let key, _, _): "folder:\(key)"
            case .file(let file): file.path
            }
        }
    }

    /// What changed under a folder. Counts leave out what git counts nothing for: binary.
    public struct Totals: Hashable, Sendable {
        public var added = 0
        public var removed = 0
        public var files = 0

        public init(added: Int = 0, removed: Int = 0, files: Int = 0) {
            self.added = added
            self.removed = removed
            self.files = files
        }

        mutating func count(_ file: ChangedFile) {
            added += file.added ?? 0
            removed += file.removed ?? 0
            files += 1
        }

        static func + (a: Totals, b: Totals) -> Totals {
            Totals(added: a.added + b.added, removed: a.removed + b.removed, files: a.files + b.files)
        }
    }

    /// One line of the tree as a list draws it.
    public struct Line: Hashable, Sendable, Identifiable {
        public var node: Node
        public var depth: Int
        public var id: String { node.id }
    }

    /// Where a file sits in the tree: relative where there is something to be relative
    /// to, its whole path otherwise (a file the runtime reported outside the folder).
    public static func components(of file: ChangedFile) -> [String] {
        let shown = file.relativePath ?? file.path
        var parts = shown.split(separator: "/").map(String.init)
        if shown.hasPrefix("/"), !parts.isEmpty { parts[0] = "/" + parts[0] }
        return parts
    }

    public static func build(_ files: [ChangedFile]) -> [Node] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [ChangedFile] = []
        }
        let top = Folder()
        for file in files {
            let parts = components(of: file)
            var folder = top
            for part in parts.dropLast() {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append(file)
        }
        func nodes(_ folder: Folder, at path: String) -> [Node] {
            let folders = folder.folders.keys.sorted(by: byName).map { name -> Node in
                var name = name
                var key = path.isEmpty ? name : path + "/" + name
                var inner = folder.folders[name]!
                // GitHub's fold: one folder and nothing else becomes part of this line.
                while inner.files.isEmpty, inner.folders.count == 1, let (only, next) = inner.folders.first {
                    name += "/" + only
                    key += "/" + only
                    inner = next
                }
                let children = nodes(inner, at: key)
                return .folder(name: name, key: key, children: children, totals: totals(of: children))
            }
            let files = folder.files.sorted { byName($0.fileName, $1.fileName) }.map(Node.file)
            return folders + files
        }
        return nodes(top, at: "")
    }

    public static func totals(of nodes: [Node]) -> Totals {
        nodes.reduce(Totals()) { sum, node in
            switch node {
            case .folder(_, _, _, let totals): return sum + totals
            case .file(let file):
                var one = Totals()
                one.count(file)
                return sum + one
            }
        }
    }

    /// The tree top to bottom, every folder open but those in `collapsed`, by key.
    public static func lines(_ nodes: [Node], collapsed: Set<String>) -> [Line] {
        var lines: [Line] = []
        func add(_ nodes: [Node], depth: Int) {
            for node in nodes {
                lines.append(Line(node: node, depth: depth))
                if case .folder(_, let key, let children, _) = node, !collapsed.contains(key) {
                    add(children, depth: depth + 1)
                }
            }
        }
        add(nodes, depth: 0)
        return lines
    }

    /// Finder's order: case aside, numbers by value.
    static func byName(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    // MARK: The Files pane

    /// What the Files pane needs from the list: each changed file by its path, and each
    /// folder that holds one, by its path, with the total under it.
    public struct Index: Hashable, Sendable {
        public var files: [String: ChangedFile] = [:]
        public var folders: [String: Totals] = [:]

        public init() {}

        public init(_ files: [ChangedFile]) {
            for file in files {
                self.files[file.path] = file
                // Every folder above it up to the filesystem's top; the pane only ever
                // asks about folders it shows, so the ones above the agent's are unasked.
                var folder = (file.path as NSString).deletingLastPathComponent
                while folder.count > 1 {
                    folders[folder, default: Totals()].count(file)
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
        }
    }
}

/// How a change is said in words: for VoiceOver, hover text and the diff's header (#63).
/// The icon and its colour carry the same, never alone.
public enum ChangeWords {
    /// The one word for what happened to a file.
    public static func status(_ state: ChangeState) -> String {
        switch state {
        case .added: "added"
        case .modified: "changed"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        case .binary: "changed, binary"
        }
    }

    /// Where a renamed file was, as its own path is shown: relative to the same top.
    public static func oldPath(of file: ChangedFile) -> String? {
        guard let old = file.oldPath else { return nil }
        guard let relative = file.relativePath, file.path.hasSuffix(relative) else { return old }
        let top = String(file.path.dropLast(relative.count))
        return old.hasPrefix(top) ? String(old.dropFirst(top.count)) : old
    }

    /// `9 lines added, 3 removed`, leaving out a side that is nothing.
    public static func lines(added: Int?, removed: Int?) -> String? {
        guard let added, let removed else { return nil }
        switch (added, removed) {
        case (0, 0): return nil
        case (_, 0): return added == 1 ? "1 line added" : "\(added) lines added"
        case (0, _): return removed == 1 ? "1 line removed" : "\(removed) lines removed"
        default: return "\(added) \(added == 1 ? "line" : "lines") added, \(removed) removed"
        }
    }

    /// Where the knowledge came from, when it is not simply the agent's edits; what the
    /// list's rows used to say under their counts, now said on hover and to VoiceOver.
    public static func source(of file: ChangedFile) -> String? {
        let edits = file.editCount == 1 ? "1 edit" : "\(file.editCount) edits"
        switch file.source {
        case .seen: return "git saw it in the folder"
        case .reportedAndSeen where file.beyondReported: return "\(edits), changed since"
        default: return file.editCount > 0 ? edits : nil
        }
    }

    /// The status said after the name: `renamed from docs/old.md`, `untracked, not in git`.
    public static func statusPhrase(_ file: ChangedFile) -> String {
        switch file.state {
        case .renamed: oldPath(of: file).map { "renamed from \($0)" } ?? "renamed"
        case .untracked: "untracked, not in git"
        default: status(file.state)
        }
    }

    /// One file's row, whole: `changes-pane.md, renamed from docs/changes.md, 9 lines
    /// added, 3 removed, 1 edit`.
    public static func label(_ file: ChangedFile) -> String {
        var parts = [file.fileName, statusPhrase(file)]
        if let lines = lines(added: file.added, removed: file.removed) { parts.append(lines) }
        if let source = source(of: file) { parts.append(source) }
        if file.inProgress { parts.append("still being edited") }
        return parts.joined(separator: ", ")
    }

    /// The hover text: what VoiceOver hears, less the name already on the row.
    public static func help(_ file: ChangedFile) -> String {
        var parts = [statusPhrase(file).prefix(1).capitalized + statusPhrase(file).dropFirst()]
        if let source = source(of: file) { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    /// A folder's totals: `4 changed files, 186 lines added, 68 removed`.
    public static func label(_ totals: ChangeTree.Totals) -> String {
        var parts = [totals.files == 1 ? "1 changed file" : "\(totals.files) changed files"]
        if let lines = lines(added: totals.added, removed: totals.removed) { parts.append(lines) }
        return parts.joined(separator: ", ")
    }
}
