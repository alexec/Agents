import AgentsKitCore
import Foundation

/// What was half-typed into New agent, per project, until it becomes an agent (029).
///
/// The rules — what is kept, for how long, a picture too big to keep — are
/// `DraftStore`'s, the same the Mac's window keeps by. This is only the timing, as the
/// Mac's `DraftKeeper` is: written once typing pauses, and all of it written when the
/// sheet goes away, so a phone put in a pocket mid-sentence loses nothing.
///
/// Unscoped: this app has a defaults domain of its own, so there is no Mac to write
/// over and no scratch copy sharing it.
@MainActor
final class StartDraftKeeper {
    static let shared = StartDraftKeeper()

    private let store = DraftStore()
    private var waiting: [DraftKey: Draft] = [:]
    private var pause: Task<Void, Never>?

    func draft(in project: URL) -> Draft? {
        let key = DraftKey.newAgent(folder: project)
        return waiting[key] ?? store.draft(for: key)
    }

    func note(_ text: String, _ attachments: [Attachment], in project: URL) {
        waiting[.newAgent(folder: project)] = Draft(text: text, attachments: attachments, editedAt: Date())
        pause?.cancel()
        pause = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// It became an agent, and a draft exists only until it does.
    func clear(in project: URL) {
        let key = DraftKey.newAgent(folder: project)
        waiting[key] = nil
        store.clear(key)
    }

    func flush() {
        pause?.cancel()
        for (key, draft) in waiting { store.save(draft, for: key) }
        waiting = [:]
    }
}
