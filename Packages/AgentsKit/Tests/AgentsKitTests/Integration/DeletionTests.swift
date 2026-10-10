import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Deleting archived agents (051, #398), through the real daemon.
///
/// The clock is fixed and the agents are seeded already archived for as long as each test
/// needs, because moving the daemon's wall clock forward by weeks inside one run is
/// exactly the jump `RetentionClock` refuses to believe.
@Suite("Deleting archived agents", .timeLimit(.minutes(1)))
struct DeletionTests {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDeletionTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ locations: StoreLocations, seeded: [Agent] = [], at time: Date? = nil,
                      settings: RetentionSettings? = nil,
                      launcher: FakeLauncher = FakeLauncher(script: .init())) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded {
            try await store.save(agent)
            try await store.append(TranscriptEntry(kind: .userMessage("hello")), for: agent.id)
        }
        if let settings { try RetentionStore(locations: locations).save(.init(settings: settings)) }
        let clock = time ?? now
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                              launcher: launcher, now: { clock })
        await core.loadFromDisk()
        return core
    }

    private func archived(_ work: URL, daysAgo: Double, title: String = "old", size: Int = 0) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: work, title: title, state: .archived,
                          endedReason: .endTurn, archivedReason: .byUser,
                          archivedAt: now.addingTimeInterval(-daysAgo * day))
        agent.lastActivityAt = now.addingTimeInterval(-daysAgo * day)
        agent.costToDate = ["USD": 1.5]
        return agent
    }

    private func folderExists(_ locations: StoreLocations, _ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: locations.agent(id).path)
    }

    // MARK: US1

    @Test func anAgentArchivedThirtyOneDaysAgoIsDeletedAndLeavesNothing() async throws {
        let (locations, work) = try temporary()
        let gone = archived(work, daysAgo: 31, title: "Plan the release")
        let core = try await core(locations, seeded: [gone])

        await core.checkRetention()

        #expect(await core.agent(gone.id) == nil)
        #expect(!folderExists(locations, gone.id))
        #expect(await !core.listAgents(.init()).contains { $0.id == gone.id })
        // Nothing is left that names it: the project costs what its agents cost.
        let project = await core.allProjects().first { $0.folder == work }
        #expect(project?.costToDate["USD"] == nil)
        let unknown = await core.handle(method: DaemonAPI.Method.agentsUnarchive,
                                        params: try JSONValue.encoding(DaemonAPI.AgentRequest(agentID: gone.id)))
        if case .failure(let error) = unknown { #expect(error.code == DaemonAPI.Failure.noSuchAgent) }
        else { Issue.record("a deleted agent was brought back") }
    }

    @Test func anAgentArchivedTwentyNineDaysAgoIsKept() async throws {
        let (locations, work) = try temporary()
        let kept = archived(work, daysAgo: 29)
        let core = try await core(locations, seeded: [kept])
        await core.checkRetention()
        #expect(await core.agent(kept.id) != nil)
        #expect(folderExists(locations, kept.id))
    }

    @Test func nothingThatIsNotArchivedIsEverDeleted() async throws {
        let (locations, work) = try temporary()
        let old = now.addingTimeInterval(-400 * day)
        let finished = Agent(runtimeID: "claude", cwd: work, title: "finished", state: .finished,
                             createdAt: old, lastActivityAt: old, endedReason: .endTurn)
        let stopped = Agent(runtimeID: "claude", cwd: work, title: "stopped", state: .stopped,
                            createdAt: old, lastActivityAt: old, endedReason: .cancelled)
        var asking = finished
        asking.id = UUID()
        asking.archiveRequest = .requested(at: old)
        let core = try await core(locations, seeded: [finished, stopped, asking],
                                  settings: RetentionSettings(keepFor: .days7))
        await core.checkRetention()
        for id in [finished.id, stopped.id, asking.id] {
            #expect(await core.agent(id) != nil)
            #expect(folderExists(locations, id))
        }
    }

    @Test func unarchivingAndArchivingAgainStartsTheTimeAgain() async throws {
        let (locations, work) = try temporary()
        let agent = archived(work, daysAgo: 40)
        let core = try await core(locations, seeded: [agent])
        try await core.unarchive(agent.id)
        #expect(await core.agent(agent.id)?.archivedAt == nil)
        try await core.archive(agent.id)
        #expect(await core.agent(agent.id)?.archivedAt == now)
        await core.checkRetention()
        #expect(await core.agent(agent.id) != nil)
    }

    @Test func aStartSoonAfterTheTimeRanOutDeletesItWithoutHoldingStartUp() async throws {
        let (locations, work) = try temporary()
        let agent = archived(work, daysAgo: 29.9)
        let first = try await core(locations, seeded: [agent])
        await first.checkRetention()
        #expect(await first.agent(agent.id) != nil)

        // Six hours later, a new daemon on the same root.
        let later = now.addingTimeInterval(6 * 3_600)
        let store = try AgentStore(locations: locations)
        let second = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                                launcher: FakeLauncher(script: .init()), now: { later })
        await second.loadFromDisk()
        // Listed straight away: start does not wait on the check.
        #expect(await second.agent(agent.id) != nil)
        await second.checkRetention()
        #expect(await second.agent(agent.id) == nil)
    }

    @Test func aDeleteCutOffLastTimeIsFinishedAtTheNextStart() async throws {
        let (locations, work) = try temporary()
        let agent = archived(work, daysAgo: 40)
        let store = try AgentStore(locations: locations)
        try await store.save(agent)
        // The folder was set aside and the daemon died before removing it.
        await store.stop(afterSettingAside: true)
        await #expect(throws: AgentStore.Stopped.self) { try await store.delete(agent.id) }
        #expect(!folderExists(locations, agent.id))
        let aside = await store.setAside(agent.id)
        #expect(FileManager.default.fileExists(atPath: aside.path))

        let core = try await core(locations)
        #expect(await core.agent(agent.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: aside.path))
    }

    // MARK: Sizes

    /// Sizes from a table rather than the disk: a size is shown without writing gigabytes.
    private func sized(_ core: DaemonCore, _ sizes: [UUID: Int]) async {
        await core.setMeasureFolder { folder in
            sizes[UUID(uuidString: folder.lastPathComponent) ?? UUID()] ?? 0
        }
    }

    @Test func onlyArchivedAgentsCountTowardTheSize() async throws {
        let (locations, work) = try temporary()
        let live = Agent(runtimeID: "claude", cwd: work, title: "live", state: .finished, endedReason: .endTurn)
        let small = archived(work, daysAgo: 5)
        let core = try await core(locations, seeded: [live, small])
        await sized(core, [live.id: 5_000_000_000, small.id: 1_000])
        await core.checkRetention()
        #expect(await core.agent(small.id) != nil)
        #expect(await core.retentionState().archivedBytes == 1_000)
    }

    // MARK: US3

    private func set(_ core: DaemonCore, _ settings: RetentionSettings,
                     confirmed: Bool) async -> DaemonAPI.RetentionSetResult {
        await core.setRetention(.init(settings: settings, confirmed: confirmed))
    }

    @Test func aChangeThatWouldDeleteAgentsIsDescribedBeforeItIsApplied() async throws {
        let (locations, work) = try temporary()
        let agents = [archived(work, daysAgo: 10), archived(work, daysAgo: 11), archived(work, daysAgo: 12)]
        let core = try await core(locations, seeded: agents)
        await sized(core, Dictionary(uniqueKeysWithValues: agents.map { ($0.id, 1_000) }))

        let asked = await set(core, RetentionSettings(keepFor: .days7), confirmed: false)
        #expect(!asked.applied)
        #expect(asked.wouldDelete == DaemonAPI.DeletePreview(count: 3, bytes: 3_000))
        #expect(await core.retentionState().settings.keepFor == .days30)
        for agent in agents { #expect(await core.agent(agent.id) != nil) }

        let done = await set(core, RetentionSettings(keepFor: .days7), confirmed: true)
        #expect(done.applied)
        #expect(done.state?.archivedCount == 0)
        for agent in agents { #expect(await core.agent(agent.id) == nil) }
    }

    @Test func aChangeThatDeletesNothingIsAppliedAtOnce() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, seeded: [archived(work, daysAgo: 3)])
        let result = await set(core, RetentionSettings(keepFor: .days14), confirmed: false)
        #expect(result.applied)
        #expect(await core.retentionState().settings == RetentionSettings(keepFor: .days14))
    }

    @Test func neverKeepsEverythingAndSurvivesARestart() async throws {
        let (locations, work) = try temporary()
        let ancient = archived(work, daysAgo: 400)
        let core = try await core(locations, seeded: [ancient])
        await sized(core, [ancient.id: 50_000_000_000])
        _ = await set(core, RetentionSettings(keepFor: .forever), confirmed: true)
        #expect(await core.agent(ancient.id) != nil)

        let again = try await self.core(locations)
        await again.checkRetention()
        #expect(await again.agent(ancient.id) != nil)
        #expect(await again.retentionState().settings.isOff)
    }

    @Test func onlyAPersonMayChangeTheSettingsOrDelete() {
        for method in [DaemonAPI.Method.retentionSet, DaemonAPI.Method.agentsDelete] {
            #expect(ConnectionRole.control.allows(method))
            #expect(ConnectionRole.device.allows(method))
            #expect(!ConnectionRole.agent.allows(method))
            #expect(!ConnectionRole.stranger.allows(method))
        }
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.retentionState))
    }

    // MARK: US5

    private func git(_ arguments: [String], in folder: URL) async throws {
        let outcome = try await GitProcess(arguments, in: folder).run()
        guard outcome.succeeded else {
            throw GitWorktrees.Failure(message: "git \(arguments.joined(separator: " ")): \(outcome.errors)")
        }
    }

    /// A repository with one commit on main, and an app-made worktree on `agents/<name>`.
    private func repositoryWithWorktree(_ name: String) async throws -> (StoreLocations, URL, AgentWorktree) {
        let (locations, work) = try temporary()
        try await git(["init", "-q", "-b", "main"], in: work)
        try await git(["config", "user.email", "test@example.com"], in: work)
        try await git(["config", "user.name", "Test"], in: work)
        try "hello\n".write(to: work.appending(path: "README"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: work)
        try await git(["commit", "-q", "-m", "first"], in: work)
        // Where the app makes its own, which is what makes one the app's to hold or remove.
        let root = work.appending(path: "\(WorktreeName.folder)/\(name)")
        try await git(["worktree", "add", "-q", "-b", "agents/\(name)", root.path], in: work)
        let worktree = AgentWorktree(name: name, root: Project.standardize(root), branch: "agents/\(name)",
                                     project: work, base: "main", madeByApp: true)
        return (locations, work, worktree)
    }

    private func archived(in worktree: AgentWorktree, daysAgo: Double) -> Agent {
        var agent = archived(worktree.project, daysAgo: daysAgo)
        agent.cwd = worktree.root
        agent.worktree = worktree
        return agent
    }

    @Test func workInItsWorktreeKeepsItUntilThatWorkIsMerged() async throws {
        let (locations, work, worktree) = try await repositoryWithWorktree("held")
        try "draft\n".write(to: worktree.root.appending(path: "draft.txt"), atomically: true, encoding: .utf8)
        let agent = archived(in: worktree, daysAgo: 40)
        let core = try await core(locations, seeded: [agent])

        await core.checkRetention()
        #expect(await core.agent(agent.id) != nil)

        // Committed but not merged is still work only this agent explains.
        try await git(["add", "."], in: worktree.root)
        try await git(["commit", "-q", "-m", "draft"], in: worktree.root)
        await core.checkRetention()
        #expect(await core.agent(agent.id) != nil)

        // Merged: nothing is lost with it, and it goes, taking its clean worktree.
        try await git(["merge", "-q", "agents/held"], in: work)
        await core.checkRetention()
        #expect(await core.agent(agent.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: worktree.root.path))
    }

    /// A worktree git will not remove (here, locked) is left where it is, and the agent
    /// still goes: nothing in it is lost, since only a clean one gets this far.
    @Test func aWorktreeDeletingCouldNotRemoveIsLeft() async throws {
        let (locations, work, worktree) = try await repositoryWithWorktree("locked")
        try await git(["worktree", "lock", worktree.root.path], in: work)
        let old = archived(in: worktree, daysAgo: 0.1)
        let core = try await core(locations, seeded: [old])

        try await core.deleteNow(old.id)

        #expect(await core.agent(old.id) == nil)
        #expect(FileManager.default.fileExists(atPath: worktree.root.path))
    }

    @Test func aWorktreeSharedWithALiveAgentIsNotAHoldAndIsLeftForIt() async throws {
        let (locations, _, worktree) = try await repositoryWithWorktree("shared")
        try "draft\n".write(to: worktree.root.appending(path: "draft.txt"), atomically: true, encoding: .utf8)
        let old = archived(in: worktree, daysAgo: 40)
        var live = Agent(runtimeID: "claude", cwd: worktree.root, title: "branch of it", state: .finished,
                         endedReason: .endTurn)
        live.worktree = worktree
        let core = try await core(locations, seeded: [old, live])
        await core.checkRetention()
        #expect(await core.agent(old.id) == nil)
        #expect(FileManager.default.fileExists(atPath: worktree.root.appending(path: "draft.txt").path))
    }

    @Test func aWorktreeThePersonMadeIsNeverTouched() async throws {
        let (locations, _, made) = try await repositoryWithWorktree("mine")
        var theirs = made
        theirs.madeByApp = false
        let agent = archived(in: theirs, daysAgo: 40)
        let core = try await core(locations, seeded: [agent])
        await core.checkRetention()
        #expect(await core.agent(agent.id) == nil)
        #expect(FileManager.default.fileExists(atPath: made.root.path))
    }

    @Test func aRunningWorkflowAndAWatchingWindowEachHoldAnAgent() async throws {
        let (locations, work) = try temporary()
        let inRun = archived(work, daysAgo: 40), watched = archived(work, daysAgo: 40)
        let core = try await core(locations, seeded: [inRun, watched])
        await core.putRun(WorkflowRun(workflowID: "nightly", folder: work, trigger: .event(EventPattern("agent.finished")), agentID: inRun.id))
        try await core.reportPresence(.init(watching: watched.id, active: true), from: .mac, connection: UUID())
        await core.checkRetention()
        #expect(await core.agent(inRun.id) != nil)
        #expect(await core.agent(watched.id) != nil)

        await core.clearRuns()
        await core.checkRetention()
        #expect(await core.agent(inRun.id) == nil)
        #expect(await core.agent(watched.id) != nil)
    }

    // MARK: Unarchiving and branching

    @Test func unarchivingBringsItBackWhole() async throws {
        let (locations, work) = try temporary()
        var soon = archived(work, daysAgo: 27)
        soon.availableCommands = [SlashCommand(name: "review", description: "Review the code")]
        let core = try await core(locations, seeded: [soon])
        await core.checkRetention()
        try await core.unarchive(soon.id)
        let back = await core.agent(soon.id)
        #expect(back?.archivedAt == nil)
        #expect(back?.availableCommands.map(\.name) == ["review"])
        #expect(try await core.transcript(.init(agentID: soon.id)).entries.isEmpty == false)
    }

    @Test func aBranchKeepsItsOwnConversationWhenTheOriginalIsDeleted() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.sessionCapabilities = ["close": [:], "list": [:], "fork": [:]]
        var original = archived(work, daysAgo: 40)
        original.runtimeSessionID = "session-1"
        let core = try await core(locations, seeded: [original],
                                  settings: RetentionSettings(keepFor: .forever),
                                  launcher: FakeLauncher(script: script))
        let branch = try await core.fork(agentID: original.id)
        let before = try await core.transcript(.init(agentID: branch)).entries.count
        #expect(before > 0)

        // Branching read it whole, which holds it for ten minutes; those have passed.
        await core.forgetReads()
        _ = await core.setRetention(.init(settings: RetentionSettings(), confirmed: true))
        #expect(await core.agent(original.id) == nil)
        #expect(await core.agent(branch) != nil)
        #expect(try await core.transcript(.init(agentID: branch)).entries.count >= before)
    }

    // MARK: Delete (#398)

    @Test func deleteRemovesAnArchivedAgentAtOnce() async throws {
        let (locations, work) = try temporary()
        let recent = archived(work, daysAgo: 0.1)
        let core = try await core(locations, seeded: [recent])
        let answer = await core.handle(method: DaemonAPI.Method.agentsDelete,
                                       params: try JSONValue.encoding(DaemonAPI.AgentRequest(agentID: recent.id)))
        guard case .success = answer else { Issue.record("delete was refused: \(answer)"); return }
        #expect(await core.agent(recent.id) == nil)
        #expect(!folderExists(locations, recent.id))
    }

    @Test func deleteIsRefusedForALiveAgentAHeldOneAndADeletedOne() async throws {
        let (locations, work) = try temporary()
        let live = Agent(runtimeID: "claude", cwd: work, title: "live", state: .finished, endedReason: .endTurn)
        let held = archived(work, daysAgo: 3)
        let core = try await core(locations, seeded: [live, held])
        await core.putRun(WorkflowRun(workflowID: "nightly", folder: work, trigger: .event(EventPattern("agent.finished")), agentID: held.id))

        do {
            try await core.deleteNow(live.id)
            Issue.record("a live agent was deleted")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.deleteRefused)
            #expect(error.message == DeletionWords.notArchived)
        }
        do {
            try await core.deleteNow(held.id)
            Issue.record("a held agent was deleted")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.deleteRefused)
            #expect(error.message == DeletionWords.refusal(.workflowRunning))
        }
        await core.clearRuns()
        try await core.deleteNow(held.id)
        do {
            try await core.deleteNow(held.id)
            Issue.record("deleted twice")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.noSuchAgent)
        }
    }

    @Test func deleteIsRefusedWhileItsWorktreeHasWork() async throws {
        let (locations, _, worktree) = try await repositoryWithWorktree("busy")
        try "draft\n".write(to: worktree.root.appending(path: "draft.txt"), atomically: true, encoding: .utf8)
        let agent = archived(in: worktree, daysAgo: 0.1)
        let core = try await core(locations, seeded: [agent])
        do {
            try await core.deleteNow(agent.id)
            Issue.record("an agent with work in its worktree was deleted")
        } catch let error as JSONRPCError {
            #expect(error.message == DeletionWords.refusal(.worktreeHasWork))
        }
        #expect(await core.agent(agent.id) != nil)
    }

    @Test func deleteIsNotStoppedByTheWindowThatAsked() async throws {
        let (locations, work) = try temporary()
        let open = archived(work, daysAgo: 3)
        let core = try await core(locations, seeded: [open])
        try await core.reportPresence(.init(watching: open.id, active: true), from: .mac, connection: UUID())
        try await core.deleteNow(open.id)
        #expect(await core.agent(open.id) == nil)
    }
}

extension DaemonCore {
    /// For the tests: a workflow run in flight, and none.
    func putRun(_ run: WorkflowRun) { workflowRuns["test-\(run.id)"] = run }
    func clearRuns() { workflowRuns.removeAll() }
    /// For the tests: as if ten minutes had passed since anything was read.
    func forgetReads() { lastWhole.removeAll() }
}
