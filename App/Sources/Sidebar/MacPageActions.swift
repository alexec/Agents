import AgentsKitCore
import AppKit
import SwiftUI

/// What a live page gets (034): its pictures from the agent's host, and that host's
/// daemon for saving, which is the one writer (022). This Mac's page is read the way a
/// server's is (037, 058).
enum MacPageActions {
    @MainActor
    static func make(model: AppModel, agentID: UUID) -> PageActions {
        let host = model.work.agent(agentID)?.host ?? .mac
        let pictures = model.serverPictures(host)
        return PageActions(
            save: { path, document in
                await model.writeArtifact(agentID: agentID, path: path, text: document)
            },
            image: { url in await pictures.image(agentID: agentID, url: url) },
            stamp: { url in await pictures.stamp(agentID: agentID, url: url) },
            canEdit: !model.hosts.isOffline(host))
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
    /// About a page or two of diagrams, as the phone keeps (#175, #213).
    private var held = LRUCache<URL, Held>(limit: 24)

    init(files: RemoteFiles) { self.files = files }

    func stamp(agentID: UUID, url: URL) async -> FileStamp? {
        await refresh(agentID: agentID, url: url)?.stamp
    }

    func image(agentID: UUID, url: URL) async -> NSImage? {
        if let image = held.value(for: url)?.image { return image }
        return await refresh(agentID: agentID, url: url)?.image
    }

    private func refresh(agentID: UUID, url: URL) async -> Held? {
        let known = held.peek(url)
        guard let reading = try? await files.read(agentID: agentID, path: url.path(percentEncoded: false),
                                                  known: known?.stamp) else { return known }
        switch reading {
        case .unchanged:
            return known
        case .image(let bytes, _, let stamp):
            let fresh = Held(stamp: stamp, image: NSImage(data: bytes))
            held.set(fresh, for: url)
            return fresh
        case .text(_, _, _, let stamp), .other(_, _, let stamp):
            let fresh = Held(stamp: stamp, image: nil)
            held.set(fresh, for: url)
            return fresh
        }
    }
}
