import Foundation

/// Reads one level of a folder, and only one.
///
/// The pane never walks the tree. That is what keeps a folder of fifty thousand
/// entries, or one with `node_modules` in it, from costing anything: it is a list of
/// names, which draws lazily like any list (FR-015).
public enum DirectoryReader {
    /// More than this in one directory and nobody is reading the rest of them anyway.
    /// The listing says how many it left out rather than pretending it is complete.
    public static let entryLimit = 5_000

    public enum Failure: Error, Equatable {
        case gone
        case notADirectory
        case notReadable
    }

    public static func read(_ url: URL, limit: Int = entryLimit) throws -> DirectoryListing {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard let values else { throw Failure.gone }
        guard values.isDirectory == true else { throw Failure.notADirectory }

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants]
        ) else {
            // The directory was there a moment ago and is not now, or it cannot be
            // opened. Both are things the pane says out loud rather than showing empty.
            throw (FileManager.default.fileExists(atPath: url.path) ? Failure.notReadable : Failure.gone)
        }

        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(min(urls.count, limit))
        for child in urls {
            // An entry that vanished between listing the directory and asking about it
            // is simply not in the answer. It is not an error for the whole listing.
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            entries.append(DirectoryEntry(url: child,
                                          name: values?.name ?? child.lastPathComponent,
                                          isDirectory: isDirectory,
                                          size: isDirectory ? nil : values?.fileSize,
                                          modifiedAt: values?.contentModificationDate))
        }

        // Directories first, then files, each by name and ignoring case. This is what
        // a person scanning a folder expects, and it does not change under them when a
        // file is written.
        entries.sort { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }

        let omitted = max(0, entries.count - limit)
        if omitted > 0 { entries = Array(entries.prefix(limit)) }
        return DirectoryListing(url: url, entries: entries, omitted: omitted)
    }
}
