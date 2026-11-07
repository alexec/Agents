import AgentsKitCore
import Foundation

/// What was half-typed into New session, per folder, until it becomes an agent (029),
/// and into each conversation until it is sent (033).
///
/// The rules — what is kept, for how long, a picture too big to keep — are
/// `DraftStore`'s, the same the Mac's window keeps by. This is only the timing, as the
/// Mac's `DraftKeeper` is: written once typing pauses, and all of it written when the
/// page goes away, so a phone put in a pocket mid-sentence loses nothing.
///
/// Unscoped: this app has a defaults domain of its own, so there is no Mac to write
/// over and no scratch copy sharing it.
@MainActor
final class StartDraftKeeper {
    static let shared = StartDraftKeeper()

    private let store: DraftStore
    private var waiting: [DraftKey: Draft] = [:]
    private var pause: Task<Void, Never>?
    /// The agents with a draft kept, once the launch's sweep has said (#3749), as the Mac's
    /// `DraftKeeper` keeps them. Nil until then: an archived agent's draft waits for it
    /// rather than costing a pass of its own.
    private var drafted: Set<UUID>?

    init(store: DraftStore = DraftStore()) {
        self.store = store
        // The one pass over the defaults, off the main thread: it lets go of the drafts
        // untouched for 30 days, as the Mac's launch does (#3749).
        Task.detached(priority: .utility) { [store] in
            let kept = store.sweep(archived: [], now: Date())
            await MainActor.run { StartDraftKeeper.shared.swept(kept) }
        }
    }

    func draft(in folder: URL) -> Draft? { draft(for: .newAgent(folder: folder)) }
    func note(_ text: String, _ attachments: [Attachment], in folder: URL) {
        note(text, attachments, for: .newAgent(folder: folder))
    }
    /// It became an agent, and a draft exists only until it does.
    func clear(in folder: URL) { clear(.newAgent(folder: folder)) }

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
        if case .agent(let id) = key { drafted?.remove(id) }
    }

    /// The control plane was forgotten (#3670): every draft goes, and nothing waiting is
    /// written back after.
    func forgetAll() {
        pause?.cancel()
        waiting = [:]
        if drafted != nil { drafted = [] }
        store.clearAll()
    }

    func flush() {
        pause?.cancel()
        for (key, draft) in waiting {
            store.save(draft, for: key)
            guard case .agent(let id) = key else { continue }
            if draft.isEmpty { drafted?.remove(id) } else { drafted?.insert(id) }
        }
        waiting = [:]
    }

    private func swept(_ kept: Set<UUID>) {
        // Anything typed while it ran is kept too.
        drafted = kept.union(waiting.keys.compactMap { if case .agent(let id) = $0 { id } else { nil } })
    }

    /// Let go of the drafts of agents archived (#3749), as the Mac does. Only an agent known
    /// to be archived costs its draft — the list may not have arrived yet, and an absence is
    /// not evidence. Only the agents with a draft are looked at, each by id (#176).
    func sweep(agents: AgentsModel) {
        guard let drafted, !drafted.isEmpty else { return }
        for id in drafted where agents.agent(id)?.state == .archived { clear(.agent(id)) }
    }
}
