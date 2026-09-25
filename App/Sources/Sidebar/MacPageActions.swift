import AgentsKit
import AppKit
import SwiftUI

/// What a live page gets from the Mac (034): its own disk for pictures, and the
/// daemon for saving, which is the one writer (022).
enum MacPageActions {
    @MainActor
    static func make(model: AppModel, agentID: UUID) -> PageActions {
        // A server agent's page is on the server, and so are its pictures (037).
        if let host = model.work.agent(agentID)?.host, host != .mac {
            let pictures = model.serverPictures(host)
            return PageActions(
                save: { path, document in
                    await model.writeArtifact(agentID: agentID, path: path, text: document)
                },
                image: { url in await pictures.image(agentID: agentID, url: url) },
                stamp: { url in await pictures.stamp(agentID: agentID, url: url) },
                canEdit: !model.hosts.isOffline(host))
        }
        return PageActions(
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

/// A server's pictures, read through its daemon and kept while the app runs (037). The
/// Mac's twin of the phone's `PhonePictures`: each is held with the stamp it was read at,
/// so asking whether it changed costs one small request and no bytes. `NSImage` reads
/// SVG itself, so there is no web view to draw one in.
@MainActor
final class ServerPictures {
    private struct Held {
        var stamp: FileStamp
        var image: NSImage?
    }

    private let files: RemoteFiles
    private var held: [URL: Held] = [:]

    init(files: RemoteFiles) { self.files = files }

    func stamp(agentID: UUID, url: URL) async -> FileStamp? {
        await refresh(agentID: agentID, url: url)?.stamp
    }

    func image(agentID: UUID, url: URL) async -> NSImage? {
        if let image = held[url]?.image { return image }
        return await refresh(agentID: agentID, url: url)?.image
    }

    private func refresh(agentID: UUID, url: URL) async -> Held? {
        let known = held[url]
        guard let reading = try? await files.read(agentID: agentID, path: url.path(percentEncoded: false),
                                                  known: known?.stamp) else { return known }
        switch reading {
        case .unchanged:
            return known
        case .image(let bytes, _, let stamp):
            let fresh = Held(stamp: stamp, image: NSImage(data: bytes))
            held[url] = fresh
            return fresh
        case .text(_, _, _, let stamp), .other(_, _, let stamp):
            let fresh = Held(stamp: stamp, image: nil)
            held[url] = fresh
            return fresh
        }
    }
}
