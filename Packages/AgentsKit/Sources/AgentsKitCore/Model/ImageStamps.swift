import Foundation

/// Which image files the page is showing, and when each was last changed.
///
/// A redrawn diagram does not change the document's text, so the line diff cannot see
/// it. The stamp is the smallest thing that can: the file's modification date and
/// size at the last load, asked again on every folder event. A passage whose picture
/// changed is marked and followed exactly like one whose words did (022 FR-020), and
/// its token is bumped so the view loads the file again.
///
/// How a stamp is learned is the caller's (034): the Mac reads it off the disk, a phone
/// asks the Mac. Nothing else here differs between them.
///
/// Only files inside the document's own folder tree are stamped. A remote address or
/// a path outside is not fetched by the page (FR-019), so there is nothing to watch.
public struct ImageStamps: Equatable, Sendable {
    public typealias Look = @Sendable (URL) async -> FileStamp?

    struct Stamp: Equatable, Sendable {
        var url: URL
        var stamp: FileStamp?
        /// Changes when the file does. The picture is given it as identity, which is
        /// what makes it be read again rather than drawn from what was cached.
        var token = UUID()
    }

    /// Passage index → the stamps of its images, in the passage's order.
    private(set) var stamps: [Int: [Stamp]] = [:]

    public init() {}

    /// The pictures a passage may show: beside the document, never above it.
    public static func url(of source: String, base: URL) -> URL? {
        let folder = base.deletingLastPathComponent().standardizedFileURL.path
        guard let url = URL(string: source, relativeTo: base)?.standardizedFileURL,
              url.isFileURL, url.path.hasPrefix(folder) else { return nil }
        return url
    }

    /// The stamps for these passages, resolved beside the document.
    public static func take(passages: [Passage], base: URL, look: Look) async -> ImageStamps {
        var taken = ImageStamps()
        for (index, passage) in passages.enumerated() {
            let urls = passage.imageSources.compactMap { url(of: $0, base: base) }
            guard !urls.isEmpty else { continue }
            var list: [Stamp] = []
            for url in urls { list.append(Stamp(url: url, stamp: await look(url))) }
            taken.stamps[index] = list
        }
        return taken
    }

    /// The same stamps, asked again. Returns which passages' pictures changed.
    public func refreshed(look: Look) async -> (ImageStamps, changed: IndexSet) {
        var fresh = self
        var changed = IndexSet()
        for (index, list) in stamps {
            var updated: [Stamp] = []
            for stamp in list {
                let now = await look(stamp.url)
                if now != stamp.stamp {
                    changed.insert(index)
                    updated.append(Stamp(url: stamp.url, stamp: now))
                } else {
                    updated.append(stamp)
                }
            }
            fresh.stamps[index] = updated
        }
        return (fresh, changed)
    }

    /// The token for a passage's pictures, or nil when it has none. Combined, so a
    /// passage with two images reloads when either changes.
    public func token(for index: Int) -> String? {
        stamps[index]?.map(\.token.uuidString).joined()
    }

    /// What a picture's file was when last looked at, for the view's cache.
    public func stamp(of url: URL) -> FileStamp? {
        for list in stamps.values {
            if let found = list.first(where: { $0.url == url }) { return found.stamp }
        }
        return nil
    }
}
