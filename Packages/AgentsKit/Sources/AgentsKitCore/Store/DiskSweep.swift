import Foundation

/// Bounds on what the app keeps on disk for itself (#211). On 2026-10-03 the disk filled,
/// and among what filled it were folders only the app writes and nothing ever emptied.
///
/// Each rule looks at one folder's own entries, never deeper, and never follows a link out
/// of it: a link in the folder is removed as a link, and a folder that is itself a link, or
/// is reached through one below `within`, is not swept at all.
public enum DiskSweep {
    /// How long an entry in a runtime's own temporary folder is kept: OpenCode's fills
    /// with the `TemporaryDirectory.*` folders of every build its agents run.
    public static let temporaryAge: TimeInterval = 24 * 60 * 60
    /// How long a file sent from another machine to an agent's folder is kept. Long enough
    /// for the conversation it was sent into to be done with it.
    public static let attachmentAge: TimeInterval = 30 * 24 * 60 * 60
    /// How many crash notes the window keeps.
    public static let crashNotesKept = 20

    /// What a daemon sweeps as it starts: the temporary folder each runtime is given under
    /// the root, of entries older than a day. Off the start's path, since the first sweep
    /// can have a thousand folders to remove; anything a runtime it starts writes there is
    /// new, so it is never what goes.
    public static func runtimeTemporaries(_ locations: StoreLocations, now: Date = Date()) {
        let root = locations.root.path
        for launch in RuntimeLaunchCatalog.builtIn {
            guard let temporary = launch.environment["TMPDIR"] ?? nil,
                  temporary.hasPrefix(RuntimeLaunch.rootPlaceholder) else { continue }
            let folder = URL(filePath: temporary.replacingOccurrences(of: RuntimeLaunch.rootPlaceholder, with: root),
                             directoryHint: .isDirectory)
            removeOlder(than: temporaryAge, in: folder, within: locations.root, now: now)
        }
    }

    /// Remove every entry of `folder` last changed more than `age` before `now`. Says how
    /// many went. A folder that is not there is nothing to do. `within` is the folder it
    /// must really be inside, with no link on the way: an agent can replace a folder in its
    /// checkout with a link to anything.
    @discardableResult
    public static func removeOlder(than age: TimeInterval, in folder: URL, within: URL? = nil,
                                   now: Date = Date()) -> Int {
        var removed = 0
        for (entry, changed) in entries(of: folder, within: within) where now.timeIntervalSince(changed) > age {
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// Keep the newest `count` entries of `folder` whose names start with `prefix`, and
    /// remove the rest. Says how many went.
    @discardableResult
    public static func keepNewest(_ count: Int, named prefix: String = "", in folder: URL) -> Int {
        let matching = entries(of: folder).filter { $0.url.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.changed > $1.changed }
        var removed = 0
        for (entry, _) in matching.dropFirst(max(count, 0)) {
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    /// `folder`'s own entries and when each last changed. `attributesOfItem` does not
    /// follow a link, so a link is judged as the link, not as what it points to. The
    /// entries are named under the folder's real path, found once, so a link put in place
    /// of the folder afterwards is not followed either.
    static func entries(of folder: URL, within: URL? = nil) -> [(url: URL, changed: Date)] {
        guard let real = realFolder(folder, within: within),
              let names = try? FileManager.default.contentsOfDirectory(atPath: real.path) else { return [] }
        let folder = real
        return names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let changed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return nil }
            return (url, changed)
        }
    }

    /// `folder`'s real path, or nil when it is not there, is itself a link, or is not
    /// really inside `within` by the same names (a link somewhere between them).
    static func realFolder(_ folder: URL, within: URL?) -> URL? {
        let path = folder.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let real = realPath(path) else { return nil }
        if let within {
            let base = within.standardizedFileURL.path
            guard path.hasPrefix(base + "/"), let realBase = realPath(base),
                  real == realBase + path.dropFirst(base.count) else { return nil }
        }
        return URL(filePath: real, directoryHint: .isDirectory)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
