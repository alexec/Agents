import Foundation

/// Bounds on what the app keeps on disk for itself (#211). On 2026-10-03 the disk filled,
/// and among what filled it were folders only the app writes and nothing ever emptied.
///
/// Each rule looks at one folder's own entries, never deeper, and never follows a link out
/// of it: a link in the folder is removed as a link.
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
            removeOlder(than: temporaryAge, in: folder, now: now)
        }
    }

    /// Remove every entry of `folder` last changed more than `age` before `now`. Says how
    /// many went. A folder that is not there is nothing to do.
    @discardableResult
    public static func removeOlder(than age: TimeInterval, in folder: URL, now: Date = Date()) -> Int {
        var removed = 0
        for (entry, changed) in entries(of: folder) where now.timeIntervalSince(changed) > age {
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
    /// follow a link, so a link is judged as the link, not as what it points to.
    static func entries(of folder: URL) -> [(url: URL, changed: Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard let changed = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return nil }
            return (url, changed)
        }
    }
}
