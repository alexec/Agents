import AgentsKitCore
import SwiftUI

/// The Page: the Mac's live page, on the phone (034).
///
/// The same `LivePage` the Mac draws, fed from the file on the Mac rather than from
/// what the conversation carried. It reads the file when it opens and again each time
/// the Mac says the file's folder changed, asking with the stamp it holds so an
/// unchanged file costs nothing. What the person types goes back through
/// `artifact/write`, as it does from the Mac, so the agent is told the same way.
struct PagePane: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    private enum Loaded: Equatable {
        case reading
        /// The agent has shown a file it has not written yet: the page opens empty, with
        /// the file's name, and fills when it appears (US1 scenario 1).
        case notYet
        case text(String, isTruncated: Bool, size: Int, stamp: FileStamp)
        /// It was here and is not now. The last text is kept, and said to be gone.
        case gone(last: String)
        /// It cannot be shown as a page: out of the agent's folders, or not text.
        case refused(String)
    }

    @State private var loaded = Loaded.reading
    @State private var reading = 0
    /// Told to the page once the file has been read again after the Mac came back, and
    /// not before: a draft carried across the text the page already had would be saved
    /// over whatever the agent wrote while the phone was away.
    @State private var readAfterReconnecting = 0

    private var state: PaneState { model.panes.state(for: agent.id) }
    private var url: URL? { state.pagePath.map { URL(filePath: $0) } }
    private var folder: URL? { url?.deletingLastPathComponent() }

    var body: some View {
        Group {
            if let url {
                page(url)
            } else {
                ContentUnavailableView("No page yet", systemImage: "doc.richtext",
                                       description: Text("A Markdown file the agent shows, or one you open in Files, reads here."))
            }
        }
        .task(id: state.pagePath) { await open() }
        .onChange(of: folder.map { model.files.changeCount(agentID: agent.id, folder: $0) }) {
            Task { await read() }
        }
        .onChange(of: model.files.reconnections) {
            Task {
                await read()
                await Task.yield()
                readAfterReconnecting += 1
            }
        }
    }

    @ViewBuilder
    private func page(_ url: URL) -> some View {
        VStack(spacing: 0) {
            if let note = note(url) {
                Text(note)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            switch loaded {
            case .reading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .refused(let why):
                Text(why)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                LivePage(text: text, url: url, line: state.openLine,
                         agentName: RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID,
                         folderEvent: model.files.anyChange[agent.id] ?? 0,
                         reconnection: readAfterReconnecting)
                    .opacity(isGone ? 0.6 : 1)
                    .environment(\.pageActions, actions)
            }
        }
    }

    private var text: String {
        switch loaded {
        case .text(let text, _, _, _): text
        case .gone(let last): last
        default: ""
        }
    }

    private var isGone: Bool {
        if case .gone = loaded { return true }
        return false
    }

    /// The line above the page, when there is something to say.
    private func note(_ url: URL) -> String? {
        switch loaded {
        case .notYet:
            return "Not written yet. \(url.lastPathComponent) will appear here as it is."
        case .gone:
            return "\(url.lastPathComponent) is gone. This is what it last said."
        case .text(let text, true, let size, _):
            return FileReading.truncationNote(shown: text.utf8.count, of: size)
        default:
            return nil
        }
    }

    /// The phone's side of the page: saves go to the Mac, pictures come from it, and
    /// nothing is typed while it is not answering (FR-028).
    private var actions: PageActions {
        let agentID = agent.id
        let model = model
        var actions = PageActions(
            save: { path, document in await model.writeArtifact(agentID: agentID, path: path, text: document) },
            image: { url in await model.pictures.image(agentID: agentID, url: url) },
            stamp: { url in await model.pictures.stamp(agentID: agentID, url: url) },
            canEdit: !model.isStale)
        actions.typing = { model.isTyping = $0 }
        return actions
    }

    // MARK: Reading

    private func open() async {
        loaded = .reading
        guard let folder else { return }
        await model.files.watch(agentID: agent.id, folder: folder)
        await read()
    }

    private func read() async {
        guard let url else { return }
        reading += 1
        let mine = reading
        var known: FileStamp?
        if case .text(_, _, _, let stamp) = loaded { known = stamp }
        do {
            let answer = try await model.files.read(agentID: agent.id, path: url.path, known: known)
            // A later read has started: its answer is the one to show.
            guard mine == reading else { return }
            switch answer {
            case .unchanged:
                break
            case .text(let text, let isTruncated, let size, let stamp):
                loaded = .text(text, isTruncated: isTruncated, size: size, stamp: stamp)
            case .image, .other:
                loaded = .refused("\(url.lastPathComponent) is not text, so it cannot be read as a page.")
            }
        } catch {
            guard mine == reading else { return }
            if RemoteFiles.isGone(error) {
                switch loaded {
                case .text(let text, _, _, _): loaded = .gone(last: text)
                case .gone: break
                default: loaded = .notYet
                }
            } else if model.isStale {
                // Keep what is on screen; the stale banner already says why.
                if case .reading = loaded { loaded = .refused(RemoteFiles.describe(error, name: url.lastPathComponent)) }
            } else {
                loaded = .refused(RemoteFiles.describe(error, name: url.lastPathComponent))
            }
        }
    }
}
