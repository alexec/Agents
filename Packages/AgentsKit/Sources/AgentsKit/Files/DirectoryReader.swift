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

        // Names first, which is one read of the directory and no stat at all (#216).
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            // The directory was there a moment ago and is not now, or it cannot be
            // opened. Both are things the pane says out loud rather than showing empty.
            throw (FileManager.default.fileExists(atPath: url.path) ? Failure.notReadable : Failure.gone)
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        let statted = candidates(names, limit: limit)
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(statted.count)
        for name in statted {
            // An entry that vanished between listing the directory and asking about it
            // is simply not in the answer. It is not an error for the whole listing.
            let child = url.appending(path: name, directoryHint: .notDirectory)
            let values = try? child.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory ?? false
            entries.append(DirectoryEntry(url: isDirectory ? url.appending(path: name, directoryHint: .isDirectory) : child,
                                          name: values?.name ?? name,
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

        if entries.count > limit { entries = Array(entries.prefix(limit)) }
        return DirectoryListing(url: url, entries: entries, omitted: max(0, names.count - entries.count))
    }

    /// The names worth a stat: all of them up to twice the limit, and past that the first
    /// twice-the-limit by name (#216). Fifty thousand entries cost a list of names and ten
    /// thousand stats, not fifty thousand. A folder that far over the limit may show a
    /// subfolder late in the alphabet among the files left out; it says how many it left.
    static func candidates(_ names: [String], limit: Int) -> [String] {
        let most = max(limit, 0) * 2
        guard names.count > most else { return names }
        return names.map { ($0.lowercased(), $0) }.sorted { $0.0 < $1.0 }.prefix(most).map(\.1)
    }
}
