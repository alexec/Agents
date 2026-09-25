import AgentsKit
import AppKit
import SwiftUI

/// What a live page gets from the Mac (034): its own disk for pictures, and the
/// daemon for saving, which is the one writer (022).
enum MacPageActions {
    @MainActor
    static func make(model: AppModel, agentID: UUID) -> PageActions {
        PageActions(
            save: { path, document in
                await model.writeArtifact(agentID: agentID, path: path, text: document)
            },
            image: { url in Pictures.image(at: url) },
            stamp: { url in Pictures.stamp(of: url) },
            canEdit: true)
    }

    /// Decoded once per file and per change to it. The page redraws whenever a
    /// passage is marked, and reading the picture off the disk each time was the one
    /// slow thing on a page of text.
    @MainActor
    private enum Pictures {
        private static let cache = NSCache<NSString, NSImage>()

        static func image(at url: URL) -> NSImage? {
            let key = "\(url.path)|\(stamp(of: url).map { "\($0.size)-\($0.modifiedAt.timeIntervalSince1970)" } ?? "")"
            if let cached = cache.object(forKey: key as NSString) { return cached }
            guard let loaded = NSImage(contentsOf: url) else { return nil }
            cache.setObject(loaded, forKey: key as NSString)
            return loaded
        }

        nonisolated static func stamp(of url: URL) -> FileStamp? {
            var url = url
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            return FileStamp(size: size, modifiedAt: modified)
        }
    }
}
