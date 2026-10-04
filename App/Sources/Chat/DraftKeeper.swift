import AgentsKitCore
import AppKit
import Foundation
import SwiftUI

/// What the window keeps of what you had half-typed, across a relaunch (025 US5).
///
/// One for the whole app, shared by every prompt bar in every window. A draft belongs to
/// its conversation, and every window already shows the same conversation the same way —
/// the selection and the start form live on the one `AppModel` they share — so a draft
/// that behaved differently per window would be the odd one out.
///
/// The rules — what is kept, for how long, what a picture too big to keep does — are
/// `DraftStore`'s, in the kit, where they are tested. This is only the timing: when to
/// read, when to write, and putting the start form back in the right order.
@MainActor
final class DraftKeeper {
    static let shared = DraftKeeper()

    private let store: DraftStore
    /// What changed since the last write, latest per conversation. Written once typing
    /// pauses rather than on every keystroke: a draft can carry a pasted picture, and
    /// encoding that per character would be the field lagging behind the fingers.
    private var waiting: [DraftKey: Draft] = [:]
    private var pause: Task<Void, Never>?
    /// The agents with a draft kept, once the launch's sweep has said (#176). Nil until
    /// then: an archived agent's draft waits for it rather than costing a pass of its own.
    private var drafted: Set<UUID>?

    /// The start form as it was left, until every part of it has been put back.
    private var leftForm: StartDraft?
    private var putBackFields = false
    /// The options chosen on it, until the runtime they belong to has said what it offers.
    private var leftChoices: [String: JSONValue]?

    /// The ordinary root keeps plain keys; a copy of the app on any other root — a branch
    /// build, a scratch run — keeps to a scope of its own, because it shares this bundle's
    /// defaults and would otherwise write its start form over the real one.
    private static var scope: String? {
        let root = StoreLocations.default
        return root.isStandard ? nil : root.name
    }

    init(store: DraftStore = DraftStore(scope: DraftKeeper.scope)) {
        self.store = store
        leftForm = store.startDraft()
        leftChoices = leftForm?.chosen
        // The one pass over the defaults, off the main thread: it reads every key the
        // app's defaults hold and decodes each draft, to let go of the month-old ones.
        Task.detached(priority: .utility) { [store] in
            let started = ContinuousClock.now
            let kept = store.sweep(archived: [], now: Date())
            let took = ContinuousClock.now - started
            await MainActor.run { DraftKeeper.shared.swept(kept, took: took) }
        }
        // A quit inside the pause would otherwise lose the last few words typed.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DraftKeeper.shared.flush() }
        }
    }

    // MARK: The words

    func draft(for key: DraftKey) -> Draft? {
        waiting[key] ?? store.draft(for: key)
    }

    /// The bar changed. Kept once typing pauses.
    func note(_ text: String, _ attachments: [Attachment], for key: DraftKey) {
        waiting[key] = Draft(text: text, attachments: attachments, editedAt: Date())
        pause?.cancel()
        pause = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// It became a prompt, and a draft exists only until it does.
    func clear(_ key: DraftKey) {
        waiting[key] = nil
        store.clear(key)
        if case .agent(let id) = key { drafted?.remove(id) }
    }

    /// Everything waiting, written now: the bar is moving to another conversation, or
    /// the app is quitting.
    func flush() {
        pause?.cancel()
        for (key, draft) in waiting {
            store.save(draft, for: key)
            guard case .agent(let id) = key else { continue }
            if draft.isEmpty { drafted?.remove(id) } else { drafted?.insert(id) }
        }
        waiting = [:]
    }

    private func swept(_ kept: Set<UUID>, took: Duration) {
        // Anything typed while it ran is kept too.
        drafted = kept.union(waiting.keys.compactMap { if case .agent(let id) = $0 { id } else { nil } })
        Perf.measured("draft-sweep", took, "\(kept.count) drafts, off the main thread")
    }

    /// Let go of the drafts that are over. Only an agent known to be archived costs its
    /// draft — the list may not have arrived yet, and an absence is not evidence. Only the
    /// agents with a draft are looked at, each by id (#176).
    func sweep(agents: AgentsModel) {
        guard let drafted, !drafted.isEmpty else { return }
        let started = ContinuousClock.now
        let over = drafted.filter { agents.agent($0)?.state == .archived }
        for id in over { clear(.agent(id)) }
        Perf.measured("draft-sweep", ContinuousClock.now - started, "\(drafted.count) drafts, \(over.count) archived")
    }

    // MARK: The start form

    /// Put the start form back as it was left.
    ///
    /// In two parts, because they become possible at different moments. The folders and
    /// servers go back at once, and the folder only if nothing has chosen one — a project
    /// page choosing its own folder is the page being right about where it is. The
    /// runtime has to wait until the runtimes are known, and goes back only if it is still
    /// one of them; until then this keeps asking.
    func putBackStartForm(into model: AppModel) {
        guard let form = leftForm else { return }
        if !putBackFields {
            putBackFields = true
            if model.draftCwd == nil { model.draftCwd = form.cwd }
            if model.draftFolders.isEmpty { model.draftFolders = form.folders }
            if model.draftServers.isEmpty { model.draftServers = form.servers }
        }
        guard !model.availableRuntimes.isEmpty else { return }
        if let runtimeID = form.runtimeID, model.availableRuntimes.contains(where: { $0.id == runtimeID }) {
            model.draftRuntimeID = runtimeID
        } else {
            // Not here any more: the choices were that runtime's, and mean nothing to another.
            leftChoices = nil
        }
        leftForm = nil
    }

    /// The runtime has said what it offers: put back the choices made on it, where they
    /// are still choices — the same rule the form keeps a choice by.
    func putBackChoices(into model: AppModel) {
        guard leftForm == nil, let choices = leftChoices, !model.draftOptions.isEmpty else { return }
        leftChoices = nil
        for option in model.draftOptions {
            guard let chosen = choices[option.id],
                  option.isBoolean || (option.options ?? []).contains(where: { $0.value == chosen })
            else { continue }
            model.draftChosen[option.id] = chosen
        }
    }

    /// The form moved. Not written while it is still being put back, or the defaults a
    /// fresh launch fills in first would be written over what was left.
    func noteStartForm(from model: AppModel) {
        guard leftForm == nil, leftChoices == nil else { return }
        store.saveStartDraft(StartDraft(cwd: model.draftCwd, runtimeID: model.draftRuntimeID,
                                        folders: model.draftFolders, servers: model.draftServers,
                                        chosen: model.draftChosen))
    }

    /// The options could not be had, so the choices left on them cannot be put back.
    func giveUpOnChoices() {
        guard leftForm == nil else { return }
        leftChoices = nil
    }
}

/// Everything a prompt bar does about keeping what was typed in it, in one place.
///
/// A modifier rather than a dozen more handlers on the bar itself: the bar's body is
/// already long enough to test the type-checker, and this is one idea that should read as
/// one. It reads the conversation's draft when the bar appears or moves to another, notes
/// every change, and keeps the start form — whichever bar is showing it.
struct KeepsDrafts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @Binding var attachments: [Attachment]
    /// Set when a draft comes back without something it held by value.
    @Binding var lostSomething: Bool
    let key: DraftKey

    private var keeper: DraftKeeper { .shared }

    func body(content: Content) -> some View {
        content
            .onAppear {
                if text.isEmpty && attachments.isEmpty { take(key) }
                keeper.sweep(agents: model.work)
            }
            // Another conversation: what was typed here is kept against this one, and that
            // one's own comes back. Words meant for one agent never reach the next.
            .onChange(of: key) { left, arrived in
                keeper.note(text, attachments, for: left)
                keeper.flush()
                take(arrived)
            }
            .onChange(of: text) { keeper.note(text, attachments, for: key) }
            .onChange(of: attachments) { keeper.note(text, attachments, for: key) }
            // An agent archived here, or more of them arrived: only the drafts that exist are looked at.
            .onChange(of: model.work.archivals) { keeper.sweep(agents: model.work) }
            .onChange(of: model.work.agentCount) { keeper.sweep(agents: model.work) }
            .onChange(of: model.draftCwd) { keeper.noteStartForm(from: model) }
            .onChange(of: model.draftRuntimeID) { keeper.noteStartForm(from: model) }
            .onChange(of: model.draftFolders) { keeper.noteStartForm(from: model) }
            .onChange(of: model.draftServers) { keeper.noteStartForm(from: model) }
            .onChange(of: model.draftChosen) { keeper.noteStartForm(from: model) }
            .onChange(of: model.draftOptions) {
                keeper.putBackChoices(into: model)
                keeper.noteStartForm(from: model)
            }
            .onChange(of: model.draftOptionsFailure) {
                if model.draftOptionsFailure != nil { keeper.giveUpOnChoices() }
            }
    }

    private func take(_ key: DraftKey) {
        let draft = keeper.draft(for: key)
        text = draft?.text ?? ""
        attachments = draft?.attachments ?? []
        lostSomething = draft?.droppedInlineData ?? false
    }
}
