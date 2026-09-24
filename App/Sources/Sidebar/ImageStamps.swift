import AgentsKit
import Foundation

/// Which image files the page is showing, and when each was last changed.
///
/// A redrawn diagram does not change the document's text, so the line diff cannot see
/// it. The stamp is the smallest thing that can: the file's modification date and
/// size at the last load, re-read on every folder event. A passage whose picture
/// changed is marked and followed exactly like one whose words did (022 FR-020), and
/// its token is bumped so the view loads the file again.
///
/// Only files inside the document's own folder tree are stamped. A remote address or
/// a path outside is not fetched by the page (FR-019), so there is nothing to watch.
struct ImageStamps: Equatable {
    struct Stamp: Equatable {
        var url: URL
        var modified: Date?
        var size: Int?
        /// Changes when the file does. `Image` is given it as identity, which is what
        /// makes SwiftUI read the file again rather than draw what it cached.
        var token = UUID()
    }

    /// Passage index → the stamps of its images, in the passage's order.
    private(set) var stamps: [Int: [Stamp]] = [:]

    /// The stamps for these passages, resolved beside the document.
    static func take(passages: [Passage], base: URL) -> ImageStamps {
        var taken = ImageStamps()
        let folder = base.deletingLastPathComponent().standardizedFileURL.path
        for (index, passage) in passages.enumerated() {
            let urls = passage.imageSources.compactMap { source -> URL? in
                guard let url = URL(string: source, relativeTo: base)?.standardizedFileURL,
                      url.isFileURL, url.path.hasPrefix(folder) else { return nil }
                return url
            }
            guard !urls.isEmpty else { continue }
            taken.stamps[index] = urls.map { Stamp(url: $0, modified: modified($0), size: size($0)) }
        }
        return taken
    }

    /// The same stamps, re-read. Returns which passages' pictures changed.
    func refreshed() -> (ImageStamps, changed: IndexSet) {
        var fresh = self
        var changed = IndexSet()
        for (index, list) in stamps {
            fresh.stamps[index] = list.map { stamp in
                let modified = Self.modified(stamp.url)
                let size = Self.size(stamp.url)
                guard modified != stamp.modified || size != stamp.size else { return stamp }
                changed.insert(index)
                return Stamp(url: stamp.url, modified: modified, size: size)
            }
        }
        return (fresh, changed)
    }

    /// The token for a passage's pictures, or nil when it has none. Combined, so a
    /// passage with two images reloads when either changes.
    func token(for index: Int) -> String? {
        stamps[index]?.map(\.token.uuidString).joined()
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func size(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }
}
