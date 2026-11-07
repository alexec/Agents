import Foundation

/// Files a copy of the app leaves on this device and nothing else removes (#3747): the
/// outputs the Mac window copied to its temporary folder for TextEdit, and the voice
/// models an older app linked into FluidAudio's cache.
public enum Leftovers {
    /// Removes the files in `folder` whose name starts with `prefix` and that were last
    /// changed more than `age` before `now`. A newer one may still be open in TextEdit.
    /// Gives the number removed.
    @discardableResult
    public static func removeOld(in folder: URL, prefix: String, olderThan age: TimeInterval,
                                 now: Date = Date()) -> Int {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            let url = folder.appendingPathComponent(name)
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard now.timeIntervalSince(changed) > age else { continue }
            if (try? files.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Removes every entry of `folder` not named in `keeping`: what an older version left
    /// next to the current one. Gives the number removed.
    @discardableResult
    public static func removeAll(in folder: URL, except keeping: Set<String>) -> Int {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed = 0
        for name in names where !keeping.contains(name) {
            if (try? files.removeItem(at: folder.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
