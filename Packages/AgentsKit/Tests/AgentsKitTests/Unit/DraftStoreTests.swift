import Foundation
import Testing
@testable import AgentsKitCore

/// Swift Testing has an `Attachment` of its own; this file means the prompt's.
private typealias Attachment = AgentsKitCore.Attachment

/// 025 US5: what you had half-typed is still there.
///
/// The rules, tested without a window: where a draft is kept, when it goes, and what
/// happens to a pasted picture too large to be worth keeping. Each test has a defaults
/// domain of its own, so nothing here reads or writes the app's.
@Suite("Drafts")
struct DraftStoreTests {
    private func store() -> (DraftStore, UserDefaults, String) {
        let suite = "AgentsDraftTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (DraftStore(defaults: defaults), defaults, suite)
    }

    private func draft(_ text: String = "Three paragraphs about the job",
                       attachments: [Attachment] = [],
                       at: Date = Date()) -> Draft {
        Draft(text: text, attachments: attachments, editedAt: at)
    }

    /// One attachment, made once: each carries an id of its own, so making it twice is two.
    private let aFile = Attachment.file(URL(filePath: "/tmp/somewhere/notes.md"))

    private func picture(bytes: Int) -> Attachment {
        .image(Data(repeating: 0x7F, count: bytes), mimeType: "image/png", name: "pasted.png")
    }

    // MARK: Kept against the conversation it was typed for

    @Test func aDraftComesBackForItsConversationAndNoOther() {
        let (store, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let one = UUID(), other = UUID()
        let written = draft(attachments: [aFile])

        store.save(written, for: .agent(one))

        #expect(store.draft(for: .agent(one)) == written)
        #expect(store.draft(for: .agent(other)) == nil)
        #expect(store.draft(for: .newAgent(folder: nil)) == nil)
    }

    /// Another store on the same defaults is another window, or the app next week.
    @Test func aDraftSurvivesTheStoreThatWroteIt() {
        let (store, defaults, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = UUID()
        store.save(draft(), for: .agent(id))

        #expect(DraftStore(defaults: defaults).draft(for: .agent(id))?.text == "Three paragraphs about the job")
    }

    /// FR-021: a draft exists only until it becomes a prompt, and an emptied field is not
    /// a draft.
    @Test func clearingOrEmptyingItLeavesNothing() {
        let (store, defaults, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = UUID()
        store.save(draft(), for: .agent(id))
        store.clear(.agent(id))
        #expect(store.draft(for: .agent(id)) == nil)

        store.save(draft(), for: .agent(id))
        store.save(draft(""), for: .agent(id))
        #expect(store.draft(for: .agent(id)) == nil)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(DraftStore.prefix) }.isEmpty,
                "nothing left behind under the draft prefix")
    }

    @Test func eachKeyIsItsOwnPlace() {
        let one = UUID()
        let keys: [DraftKey] = [.agent(one), .agent(UUID()),
                                .newAgent(folder: nil),
                                .newAgent(folder: URL(filePath: "/tmp/somewhere/api")),
                                .newAgent(folder: URL(filePath: "/tmp/somewhere/web"))]
        let store = DraftStore(defaults: UserDefaults(suiteName: "unused-\(UUID().uuidString)")!)
        #expect(Set(keys.map { store.defaultsKey(for: $0) }).count == keys.count)
        #expect(keys.allSatisfy { store.defaultsKey(for: $0).hasPrefix(DraftStore.prefix) })
        #expect(DraftKey.agent(one).name == DraftKey.agent(one).name, "stable")
        #expect(DraftKey.newAgent(folder: URL(filePath: "/tmp/somewhere/api/"))
                == DraftKey.newAgent(folder: URL(filePath: "/tmp/somewhere/api")),
                "a folder is the same folder with or without its trailing slash")
    }

    // MARK: FR-022: when a draft goes

    @Test func theSweepDropsADraftWhoseConversationIsArchived() {
        let (store, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let archived = UUID(), working = UUID()
        store.save(draft(), for: .agent(archived))
        store.save(draft(), for: .agent(working))

        store.sweep(archived: [archived], now: Date())

        #expect(store.draft(for: .agent(archived)) == nil)
        #expect(store.draft(for: .agent(working)) != nil)
    }

    /// The sweep runs before the agent list may have arrived. An agent it has not heard
    /// of is not evidence of anything, so it costs no draft — only "known, and archived"
    /// does, and the thirty days catches whatever is truly gone.
    @Test func anAgentTheSweepHasNotHeardOfCostsNothing() {
        let (store, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = UUID()
        store.save(draft(), for: .agent(id))

        store.sweep(archived: [], now: Date())

        #expect(store.draft(for: .agent(id)) != nil)
    }

    @Test func aDraftUntouchedForThirtyDaysGoes() {
        let (store, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let now = Date()
        let old = UUID(), recent = UUID()
        store.save(draft(at: now.addingTimeInterval(-DraftStore.horizon - 60)), for: .agent(old))
        store.save(draft(at: now.addingTimeInterval(-60)), for: .agent(recent))
        store.save(draft(at: now.addingTimeInterval(-DraftStore.horizon - 60)), for: .newAgent(folder: nil))

        store.sweep(archived: [], now: now)

        #expect(store.draft(for: .agent(old)) == nil)
        #expect(store.draft(for: .newAgent(folder: nil)) == nil)
        #expect(store.draft(for: .agent(recent)) != nil)
    }

    /// FR-026 in the window's terms: a draft is never worth failing over.
    @Test func anEntryThatWillNotDecodeIsDiscarded() {
        let (store, defaults, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = UUID()
        defaults.set(Data("{ not a draft".utf8), forKey: store.defaultsKey(for: .agent(id)))

        #expect(store.draft(for: .agent(id)) == nil)
        #expect(defaults.object(forKey: store.defaultsKey(for: .agent(id))) == nil, "and not left to fail again")
    }

    // MARK: A pasted picture too large to keep

    @Test func inlineDataOverTheCapIsDroppedAndSaysSo() {
        let (store, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = UUID()
        let big = picture(bytes: DraftStore.inlineCap + 1)
        store.save(draft(attachments: [aFile, big]), for: .agent(id))

        let back = store.draft(for: .agent(id))
        #expect(back?.text == "Three paragraphs about the job", "the words are always kept")
        #expect(back?.attachments == [aFile], "and anything sent by reference")
        #expect(back?.droppedInlineData == true, "and it says what it could not keep")
    }

    @Test func inlineDataUnderTheCapIsKept() {
        let (store, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = UUID()
        let small = picture(bytes: 2_048)
        store.save(draft(attachments: [small, aFile]), for: .agent(id))

        let back = store.draft(for: .agent(id))
        #expect(back?.attachments == [small, aFile])
        #expect(back?.droppedInlineData == false)
    }

    /// A draft whose only content was too big still says so rather than vanishing.
    @Test func aDraftThatWasOnlyAPictureStillSaysSo() {
        let (store, _, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let id = UUID()
        store.save(draft("", attachments: [picture(bytes: DraftStore.inlineCap + 1)]), for: .agent(id))

        #expect(store.draft(for: .agent(id))?.droppedInlineData == true)
    }

    // MARK: The start form

    @Test func theStartFormComesBack() {
        let (store, defaults, suite) = store()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let form = StartDraft(cwd: URL(filePath: "/tmp/somewhere/api"), runtimeID: "grok",
                              folders: [URL(filePath: "/tmp/somewhere/shared")],
                              servers: [], chosen: ["model": "grok-4"])
        store.saveStartDraft(form)

        #expect(DraftStore(defaults: defaults).startDraft() == form)
    }

    // MARK: One root's drafts are that root's

    /// A copy of the app on a scratch root shares the ordinary app's defaults. Neither may
    /// see, overwrite or sweep the other's drafts or start form.
    @Test func aScratchRootsDraftsAreItsOwn() {
        let suite = "AgentsDraftTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let ordinary = DraftStore(defaults: defaults)
        let scratch = DraftStore(defaults: defaults, scope: "run-drafts")
        let id = UUID()
        ordinary.save(draft("the real one"), for: .newAgent(folder: nil))
        scratch.save(draft("a test's"), for: .newAgent(folder: nil))
        ordinary.saveStartDraft(StartDraft(runtimeID: "claude"))
        scratch.saveStartDraft(StartDraft(runtimeID: "grok"))
        scratch.save(draft(at: Date().addingTimeInterval(-DraftStore.horizon - 60)), for: .agent(id))

        #expect(ordinary.draft(for: .newAgent(folder: nil))?.text == "the real one")
        #expect(scratch.draft(for: .newAgent(folder: nil))?.text == "a test's")
        #expect(ordinary.startDraft()?.runtimeID == "claude")
        #expect(scratch.startDraft()?.runtimeID == "grok")

        // The ordinary store's sweep does not reach into a scratch root's keys, however
        // old they are, and the scratch one's does not touch the ordinary drafts.
        ordinary.sweep(archived: [id], now: Date())
        #expect(defaults.object(forKey: scratch.defaultsKey(for: .agent(id))) != nil)
        scratch.sweep(archived: [], now: Date())
        #expect(defaults.object(forKey: scratch.defaultsKey(for: .agent(id))) == nil)
        #expect(ordinary.draft(for: .newAgent(folder: nil))?.text == "the real one")
        #expect(ordinary.startDraft()?.runtimeID == "claude")
    }
}
