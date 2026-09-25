import AgentsKitCore
import Foundation

/// What was half-typed into New agent, per project, until it becomes an agent (029),
/// and into each conversation until it is sent (033).
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

    func draft(in project: URL) -> Draft? { draft(for: .newAgent(folder: project)) }
    func note(_ text: String, _ attachments: [Attachment], in project: URL) {
        note(text, attachments, for: .newAgent(folder: project))
    }
    /// It became an agent, and a draft exists only until it does.
    func clear(in project: URL) { clear(.newAgent(folder: project)) }

    // MARK: Any conversation's (033)

    /// A chat keeps its half-typed words the same way, under the key the Mac uses for
    /// the same conversation on its own disk.
    func draft(for key: DraftKey) -> Draft? {
        waiting[key] ?? store.draft(for: key)
    }

    func note(_ text: String, _ attachments: [Attachment], for key: DraftKey) {
        waiting[key] = Draft(text: text, attachments: attachments, editedAt: Date())
        pause?.cancel()
        pause = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func clear(_ key: DraftKey) {
        waiting[key] = nil
        store.clear(key)
    }

    func flush() {
        pause?.cancel()
        for (key, draft) in waiting { store.save(draft, for: key) }
        waiting = [:]
    }
}
