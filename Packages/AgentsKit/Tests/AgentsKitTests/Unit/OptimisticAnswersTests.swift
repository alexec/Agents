import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Approvals, a move to a worktree, the prompt on its way and the display choices are
/// drawn before their host answers, and go back when the call fails (#4814).
@MainActor
@Suite("Answers drawn before the host answers")
struct OptimisticAnswersTests {
    private let folder = URL(filePath: "/tmp/work/api")
    private var key: FolderKey { FolderKey(host: .mac, folder: folder) }
    private let approval = Approval(kind: .mcpServer, key: "ci", title: "ci", digest: "d1", line: "New MCP server",
                                    actions: [.approve, .deny])

    private func summary(_ approvals: [Approval]) -> DaemonAPI.FolderSummary {
        var summary = DaemonAPI.FolderSummary(folder: Folder(folder: folder), name: "api", exists: true,
                                              lastActivityAt: Date(), counts: [:])
        summary.approvals = approvals
        return summary
    }

    private func agent(state: AgentState = .finished) -> Agent {
        Agent(runtimeID: "claude", cwd: folder, title: "Something", state: state, lastActivityAt: Date())
    }

    // MARK: Approvals

    @Test func anApprovalLeavesAtOnceAndAListMeanwhileKeepsItOut() async {
        let model = AgentsModel()
        model.replaceFolders([summary([approval])])
        let sent = await model.answering(approval, in: key) {
            #expect(model.folder(key)?.approvals?.isEmpty == true)
            // The host's list from before the answer does not bring it back.
            model.upsert(summary([approval]))
            #expect(model.folder(key)?.approvals?.isEmpty == true)
            // The Review page that sent it still finds it.
            #expect(model.approval(approval.id, in: key) == approval)
            return true
        }
        #expect(sent)
        #expect(model.approval(approval.id, in: key) == nil)
    }

    @Test func aRefusedApprovalComesBack() async {
        let model = AgentsModel()
        model.replaceFolders([summary([approval])])
        let sent = await model.answering(approval, in: key) { false }
        #expect(!sent)
        #expect(model.folder(key)?.approvals == [approval])
    }

    /// Answered elsewhere while this answer was going: it does not come back.
    @Test func anApprovalAnsweredElsewhereStaysGone() async {
        let model = AgentsModel()
        model.replaceFolders([summary([approval])])
        _ = await model.answering(approval, in: key) {
            model.upsert(summary([]))
            return false
        }
        #expect(model.folder(key)?.approvals?.isEmpty == true)
    }

    @Test func theFailureLineNamesTheAnswer() {
        #expect(approval.failure(.approve, "Your Mac did not answer") == "Could not approve — your Mac did not answer")
        let archive = Approval(kind: .archive, key: "x", title: "x", digest: nil, line: "", actions: [.approve, .deny])
        #expect(archive.failure(.deny, "") == "Could not keep the session.")
    }

    // MARK: Move to a worktree

    @Test func aMoveShowsAsChosenAtOnceAndGoesBackWhenRefused() {
        let model = AgentsModel()
        let held = agent(state: .running)
        model.upsert(held)
        let write = model.beginWrite(.move(.folderPath), on: held.id)
        #expect(model.agent(held.id)?.pendingMove?.target == .folderPath)
        model.settleWrite(write, on: held.id, failed: true)
        #expect(model.agent(held.id)?.pendingMove == nil)
    }

    /// Made at once between turns: the host's answer settles it, and its record shows where.
    @Test func aMoveMadeNowIsDoneOnTheAnswer() {
        let model = AgentsModel()
        let held = agent()
        model.upsert(held)
        let write = model.beginWrite(.move(.newWorktree(name: nil)), on: held.id)
        model.settleWrite(write, on: held.id, failed: false, done: true)
        #expect(!model.hasPendingWrite(on: held.id))
        #expect(model.agent(held.id)?.pendingMove == nil)
    }

    // MARK: The prompt on its way

    @Test func aPromptIsDrawnAtOnceUntilItsEntryLands() {
        let model = AgentsModel()
        let held = agent()
        model.upsert(held)
        model.watching = held.id
        let id = model.beginSending("  Fix the tests ", to: held.id)
        #expect(model.sending(to: held.id).map(\.text) == ["Fix the tests"])
        model.endSending(id, to: held.id, sent: true)
        #expect(model.sending(to: held.id).count == 1)
        model.apply(.entry(DaemonAPI.EntryNotification(agentID: held.id,
                                                       entry: TranscriptEntry(kind: .userMessage("Fix the tests")))))
        #expect(model.sending(to: held.id).isEmpty)
    }

    @Test func aPromptThatDidNotGoLeavesTheChat() {
        let model = AgentsModel()
        let held = agent()
        model.upsert(held)
        model.watching = held.id
        let id = model.beginSending("Fix the tests", to: held.id)
        model.endSending(id, to: held.id, sent: false)
        #expect(model.sending(to: held.id).isEmpty)
    }

    /// The host took it, and the next entry it sends is its prompt, whatever the words.
    @Test func anyEntryAfterTheAnswerTakesItsPlace() {
        let model = AgentsModel()
        let held = agent()
        model.upsert(held)
        model.watching = held.id
        let id = model.beginSending("Fix @file", to: held.id)
        model.endSending(id, to: held.id, sent: true)
        model.apply(.entry(DaemonAPI.EntryNotification(agentID: held.id,
                                                       entry: TranscriptEntry(kind: .userMessage("Fix file.swift")))))
        #expect(model.sending(to: held.id).isEmpty)
    }

    /// One that will queue shows in the queue, from the host's record, and not as a bubble.
    @Test func aPromptThatQueuesIsNotDrawn() {
        let model = AgentsModel()
        let held = agent(state: .running)
        model.upsert(held)
        #expect(model.beginSending("Next", to: held.id) == nil)
        #expect(model.sending(to: held.id).isEmpty)
    }

    // MARK: Display choices

    @Test func aChoiceTheHostRefusedGoesBackAndSaysSo() async throws {
        let defaults = try #require(UserDefaults(suiteName: "OptimisticAnswersTests-\(UUID())"))
        let key = DisplayPreference.showsActivity
        var failures: [String] = []
        let mirror = DisplayPreferenceMirror(defaults: defaults) { _ in
            throw JSONRPCError(code: -1, message: "Your Mac did not answer")
        } failed: { error in
            failures.append(DisplayPreferenceMirror.failure((error as? JSONRPCError)?.message ?? ""))
        }
        mirror.hostSaid([key: .bool(false)])
        mirror.set([key: .bool(true)])
        #expect(mirror.preferences[key] == .bool(true))
        #expect(defaults.object(forKey: key) as? Bool == true)
        // A map the host sends meanwhile, for another change, does not undo it.
        mirror.hostSaid([key: .bool(false)])
        #expect(defaults.object(forKey: key) as? Bool == true)
        for _ in 0..<50 where failures.isEmpty { await Task.yield() }
        #expect(failures == ["Could not save the setting — your Mac did not answer"])
        #expect(mirror.preferences[key] == .bool(false))
        #expect(defaults.object(forKey: key) as? Bool == false)
    }
}
