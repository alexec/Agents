import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every reversible action is drawn before its host answers, and goes back when the
/// call fails (#4786). One layer in the kit, for the Mac window and the Remote alike.
@MainActor
@Suite("Changes drawn before the host answers")
struct PendingWritesTests {
    private let folder = URL(filePath: "/tmp/work/api")

    private func agent(_ id: UUID = UUID(), state: AgentState = .running, title: String = "Something") -> Agent {
        Agent(id: id, runtimeID: "claude", cwd: folder, title: title, state: state, lastActivityAt: Date())
    }

    @Test func archiveShowsAtOnceAndStaysUntilTheHostSaysSo() {
        let model = AgentsModel()
        let held = agent(state: .finished)
        model.upsert(held)
        let write = model.beginWrite(.archive, on: held.id)
        #expect(model.agent(held.id)?.state == .archived)
        #expect(model.hasPendingWrite(on: held.id))
        // A record from the host that has not done it yet does not undo what is drawn.
        model.upsert(held)
        #expect(model.agent(held.id)?.state == .archived)
        // Answered: still drawn, until the host's record comes.
        model.settleWrite(write, on: held.id, failed: false)
        #expect(model.agent(held.id)?.state == .archived)
        var archived = held
        archived.state = .archived
        model.upsert(archived)
        #expect(!model.hasPendingWrite(on: held.id))
        #expect(model.agent(held.id)?.state == .archived)
    }

    /// Start now (#5156) draws a queued session as starting, and a refusal (its folder's
    /// total is full) puts it back in the queue.
    @Test func startNowDrawsStartingAndARefusalPutsItBack() {
        let model = AgentsModel()
        var queued = agent(state: .queued)
        queued.startedByAgent = UUID()
        model.upsert(queued)
        #expect(HelperLimit.canStartNow(queued))
        let write = model.beginWrite(.startNow, on: queued.id)
        #expect(model.agent(queued.id)?.state == .starting)
        model.settleWrite(write, on: queued.id, failed: true)
        #expect(model.agent(queued.id)?.state == .queued)
        #expect(AgentWrite.startNow.failure("It was not started.") == "Could not start it now — it was not started.")
        var persons = queued
        persons.startedByAgent = nil
        #expect(!HelperLimit.canStartNow(persons))
    }

    @Test func aFailedCallPutsTheRecordBack() {
        let model = AgentsModel()
        let held = agent(state: .finished, title: "Old")
        model.upsert(held)
        let write = model.beginWrite(.rename("New"), on: held.id)
        #expect(model.agent(held.id)?.title == "New")
        #expect(model.agentTitles[held.id] == "New")
        model.settleWrite(write, on: held.id, failed: true)
        #expect(model.agent(held.id)?.title == "Old")
        #expect(model.agentTitles[held.id] == "Old")
        #expect(!model.hasPendingWrite(on: held.id))
    }

    /// The host's newer record is what goes back, not the one held when the change began.
    @Test func aRollbackKeepsWhatTheHostSaidMeanwhile() {
        let model = AgentsModel()
        let held = agent(state: .finished)
        model.upsert(held)
        let write = model.beginWrite(.mute(true), on: held.id)
        var newer = held
        newer.title = "Renamed elsewhere"
        model.upsert(newer)
        #expect(model.agent(held.id)?.isMuted == true)
        #expect(model.agent(held.id)?.title == "Renamed elsewhere")
        model.settleWrite(write, on: held.id, failed: true)
        #expect(model.agent(held.id)?.isMuted == false)
        #expect(model.agent(held.id)?.title == "Renamed elsewhere")
    }

    /// Two changes in flight: one failing leaves the other drawn.
    @Test func oneFailureLeavesTheOtherChange() {
        let model = AgentsModel()
        let held = agent(state: .finished)
        model.upsert(held)
        let mute = model.beginWrite(.mute(true), on: held.id)
        _ = model.beginWrite(.labels(add: ["bug"], remove: []), on: held.id)
        model.settleWrite(mute, on: held.id, failed: true)
        #expect(model.agent(held.id)?.isMuted == false)
        #expect(model.agent(held.id)?.labels.map(\.value) == ["bug"])
    }

    @Test func anArchivedSessionLeavesItsGroupAtOnce() {
        let model = AgentsModel()
        let held = agent(state: .finished)
        model.upsert(held)
        let key = FolderKey(host: .mac, folder: folder)
        let group = model.group(of: held)
        #expect(model.agents(in: key, group: group).map(\.id) == [held.id])
        _ = model.beginWrite(.archive, on: held.id)
        #expect(model.agents(in: key, group: group).isEmpty)
    }

    @Test func optimisticallySettlesOnTheCallsAnswer() async {
        let model = AgentsModel()
        let held = agent(state: .running)
        model.upsert(held)
        let sent = await model.optimistically(.stop, on: held.id) {
            #expect(model.agent(held.id)?.state == .stopped)
            return false
        }
        #expect(!sent)
        #expect(model.agent(held.id)?.state == .running)
    }

    @Test func unarchiveGoesBackToHowItEnded() {
        var archived = agent(state: .archived)
        archived.endedReason = .endTurn
        #expect(AgentWrite.unarchive.applied(to: archived).state == .finished)
        archived.endedReason = .cancelled
        #expect(AgentWrite.unarchive.applied(to: archived).state == .stopped)
    }

    @Test func clearingARenameGivesTheRuntimesTitleBack() {
        let renamed = AgentWrite.rename("Mine").applied(to: agent(title: "Runtime's"))
        #expect(renamed.title == "Mine")
        #expect(renamed.titleIsPersons)
        let cleared = AgentWrite.rename("").applied(to: renamed)
        #expect(cleared.title == "Runtime's")
        #expect(!cleared.titleIsPersons)
        #expect(AgentWrite.rename("").isSettled(by: cleared))
    }

    @Test func theFailureLineSaysWhatFailed() {
        #expect(AgentWrite.archive.failure("Your Mac did not answer.") == "Could not archive — your Mac did not answer.")
        #expect(AgentWrite.mute(false).failure("") == "Could not unmute.")
    }

    @Test func anAnsweredCardGoesAtOnceAndComesBackOnFailure() async {
        let model = AgentsModel()
        let id = UUID()
        let question = PermissionRequest(
            agentID: id, toolCall: ToolCall(title: "Run `git push`"),
            options: [PermissionOption(optionID: "y", name: "Allow", kind: .allowOnce)])
        model.replacePermissions([question])
        let sent = await model.answering(question) {
            #expect(model.permissions.isEmpty)
            // A list read while the answer goes does not bring it back.
            model.replacePermissions([question])
            #expect(model.permissions.isEmpty)
            return false
        }
        #expect(!sent)
        #expect(model.permissions == [question])
    }

    /// Answered on another device while ours failed: it does not come back.
    @Test func aCardSettledElsewhereStaysGone() async {
        let model = AgentsModel()
        let id = UUID()
        let question = PermissionRequest(
            agentID: id, toolCall: ToolCall(title: "Run `git push`"),
            options: [PermissionOption(optionID: "y", name: "Allow", kind: .allowOnce)])
        model.replacePermissions([question])
        _ = await model.answering(question) {
            model.apply(.permission(DaemonAPI.PermissionNotification(agentID: id, request: nil, requestID: question.id)))
            return false
        }
        #expect(model.permissions.isEmpty)
    }
}
