import Foundation

/// A file the person is naming in a prompt by typing `@`.
///
/// The same idea as a slash command and the same rule: `@` only starts a mention at the
/// start of a word, so an email address in a sentence is not a file picker.
public struct FileMention: Hashable, Sendable, Identifiable {
    public var url: URL
    /// What is shown: the path relative to the folder it was found in.
    public var relativePath: String

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }
}

public struct MentionQuery: Equatable, Sendable {
    public var start: String.Index
    public var term: String

    public init(start: String.Index, term: String) {
        self.start = start
        self.term = term
    }
}

extension FileMention {
    public static func query(in text: String) -> MentionQuery? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex {
            // Asking for the index before the first one is a crash, not a false.
            let before = text.index(before: at)
            guard text[before].isWhitespace else { return nil }
        }
        let term = String(text[text.index(after: at)...])
        guard !term.contains(where: \.isWhitespace) else { return nil }
        return MentionQuery(start: at, term: term)
    }

    /// The text with the half-typed mention replaced by this file's name.
    public func completing(_ query: MentionQuery, in text: String) -> String {
        String(text[text.startIndex..<query.start]) + name + " "
    }

    /// Files under these folders worth offering for what has been typed.
    ///
    /// Shallow and capped on purpose: this runs on every keystroke, and a repository
    /// with a hundred thousand files in it is the ordinary case rather than the odd one.
    public static func matching(_ term: String, in folders: [URL], limit: Int = 30) -> [FileMention] {
        let needle = term.lowercased()
        var found: [FileMention] = []
        let manager = FileManager.default
        for folder in folders {
            guard let walker = manager.enumerator(at: folder,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            let resolved = Self.realPath(folder)
            var seen = 0
            for case let url as URL in walker {
                seen += 1
                // A cap on how much of the tree is walked, not on what is shown, so a
                // huge folder cannot make typing slow.
                if seen > 20_000 { break }
                // Run off the main actor by the prompt bar, and cancelled by the next
                // keystroke: what was typed since is the search that matters.
                if seen % 256 == 0, Task.isCancelled { return [] }
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if url.lastPathComponent == ".git" || url.lastPathComponent == "node_modules" {
                        walker.skipDescendants()
                    }
                    continue
                }
                // The walker hands back resolved paths, so a folder reached through a
                // link (`/tmp`, `/var`) is matched by its resolved form too; otherwise
                // the whole path is shown where the part under the folder belongs.
                let relative = [folder.path, resolved.path]
                    .first { url.path.hasPrefix($0 + "/") }
                    .map { String(url.path.dropFirst($0.count + 1)) }
                    ?? url.path
                guard needle.isEmpty || relative.lowercased().contains(needle) else { continue }
                found.append(FileMention(url: url, relativePath: relative))
                if found.count >= limit { return ranked(found, term: needle) }
            }
        }
        return ranked(found, term: needle)
    }

    /// The folder as the walker will report it. Not `resolvingSymlinksInPath`, which
    /// deliberately turns `/private/var` back into `/var` — the opposite of what the
    /// walker does.
    private static func realPath(_ folder: URL) -> URL {
        guard let resolved = folder.withUnsafeFileSystemRepresentation({ $0.flatMap { realpath($0, nil) } })
        else { return folder }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }

    /// What starts with the term comes before what merely contains it, and a match on
    /// the file's own name beats one on a folder in its path.
    private static func ranked(_ found: [FileMention], term: String) -> [FileMention] {
        guard !term.isEmpty else { return found }
        return found.sorted { first, second in
            rank(first, term) < rank(second, term)
        }
    }

    private static func rank(_ mention: FileMention, _ term: String) -> Int {
        let name = mention.name.lowercased()
        if name.hasPrefix(term) { return 0 }
        if name.contains(term) { return 1 }
        return 2
    }
}
