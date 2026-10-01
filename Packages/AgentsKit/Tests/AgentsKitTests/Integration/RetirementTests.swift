import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Retiring archived agents (051), through the real daemon.
///
/// The clock is fixed and the agents are seeded already archived for as long as each test
/// needs, because moving the daemon's wall clock forward by weeks inside one run is
/// exactly the jump `RetentionClock` refuses to believe.
@Suite("Retiring archived agents", .timeLimit(.minutes(1)))
struct RetirementTests {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsRetirementTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test func anAgentArchivedThirtyOneDaysAgoIsRetiredAndLeavesATombstone() async throws {
        let (locations, work) = try temporary()
        let gone = archived(work, daysAgo: 31, title: "Plan the release")
        let core = try await core(locations, seeded: [gone])

        await core.checkRetention()

        #expect(await core.agent(gone.id) == nil)
        #expect(!folderExists(locations, gone.id))
        #expect(await !core.listAgents(.init()).contains { $0.id == gone.id })
        let tombstones = await core.retiredTombstones(.init(ids: [gone.id]))
        #expect(tombstones.first?.title == "Plan the release")
        #expect(tombstones.first?.retiredBecause == .age)
        #expect(RetiredStore(locations: locations).loadAll()[gone.id] != nil)
        // The project keeps what it cost, and counts what went.
        let project = await core.allProjects().first { $0.folder == work }
        #expect(project?.retiredCount == 1)
        #expect(project?.costToDate["USD"] == 1.5)
    }

    @Test func anAgentArchivedTwentyNineDaysAgoIsKept() async throws {
        let (locations, work) = try temporary()
        let kept = archived(work, daysAgo: 29)
        let core = try await core(locations, seeded: [kept])
        await core.checkRetention()
        #expect(await core.agent(kept.id) != nil)
        #expect(folderExists(locations, kept.id))
    }

    @Test func nothingThatIsNotArchivedIsEverRetired() async throws {
        let (locations, work) = try temporary()
        let old = now.addingTimeInterval(-400 * day)
        let finished = Agent(runtimeID: "claude", cwd: work, title: "finished", state: .finished,
                             createdAt: old, lastActivityAt: old, endedReason: .endTurn)
        let stopped = Agent(runtimeID: "claude", cwd: work, title: "stopped", state: .stopped,
                            createdAt: old, lastActivityAt: old, endedReason: .cancelled)
        var parked = finished
        parked.id = UUID()
        parked.parking = .parked(at: old)
        let core = try await core(locations, seeded: [finished, stopped, parked],
                                  settings: RetentionSettings(keepFor: .days7, cap: .gb1))
        await core.checkRetention()
        for id in [finished.id, stopped.id, parked.id] {
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

    @Test func aStartSoonAfterTheTimeRanOutRetiresItWithoutHoldingStartUp() async throws {
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

    @Test func aRetireCutOffLastTimeIsFinishedBeforeAnythingIsListed() async throws {
        let (locations, work) = try temporary()
        let agent = archived(work, daysAgo: 40)
        let store = try AgentStore(locations: locations)
        try await store.save(agent)
        // The tombstone was written and the daemon died before deleting anything.
        try RetiredStore(locations: locations).append(Tombstone(from: agent, retiredAt: now, because: .age))
        let core = try await core(locations)
        #expect(await core.agent(agent.id) == nil)
        #expect(!folderExists(locations, agent.id))
        #expect(await core.retiredTombstones(.init(ids: [agent.id])).count == 1)
    }

    @Test func aRetiredAgentSaysSoWhenAsked() async throws {
        let (locations, work) = try temporary()
        let gone = archived(work, daysAgo: 31, title: "Plan the release")
        let core = try await core(locations, seeded: [gone])
        await core.checkRetention()

        for method in [DaemonAPI.Method.agentsUnarchive, DaemonAPI.Method.agentsTranscript] {
            let answer = await core.handle(method: method,
                                           params: try JSONValue.encoding(DaemonAPI.AgentRequest(agentID: gone.id)))
            guard case .failure(let error) = answer else {
                Issue.record("\(method) answered for a retired agent")
                continue
            }
            #expect(error.code == DaemonAPI.Failure.agentRetired, "\(method)")
            #expect(error.message.contains("Plan the release"), "\(method)")
        }
        // An id nobody has ever heard of is still just not here.
        let unknown = await core.handle(method: DaemonAPI.Method.agentsUnarchive,
                                        params: try JSONValue.encoding(DaemonAPI.AgentRequest(agentID: UUID())))
        if case .failure(let error) = unknown { #expect(error.code == DaemonAPI.Failure.noSuchAgent) }
    }

    // MARK: US2

    /// Sizes from a table rather than the disk: a cap is crossed without writing gigabytes.
    private func sized(_ core: DaemonCore, _ sizes: [UUID: Int]) async {
        await core.setMeasureFolder { folder in
            sizes[UUID(uuidString: folder.lastPathComponent) ?? UUID()] ?? 0
        }
    }

    @Test func overTheCapTheOldestGoFirstAndNoneOnItsFirstDay() async throws {
        let (locations, work) = try temporary()
        let mb = 1_000_000
        let a = archived(work, daysAgo: 10), b = archived(work, daysAgo: 9)
        let c = archived(work, daysAgo: 8), fresh = archived(work, daysAgo: 0.5)
        let core = try await core(locations, seeded: [a, b, c, fresh],
                                  settings: RetentionSettings(keepFor: .days30, cap: .gb1))
        await sized(core, [a.id: 400 * mb, b.id: 400 * mb, c.id: 400 * mb, fresh.id: 400 * mb])
        await core.checkRetention()
        #expect(await core.agent(a.id) == nil)
        #expect(await core.agent(b.id) == nil)
        #expect(await core.agent(c.id) != nil)
        #expect(await core.agent(fresh.id) != nil)
        #expect(await core.retiredTombstones(.init(ids: [a.id])).first?.retiredBecause == .cap)
    }

    @Test func overTheCapWithNothingThatCanGoSaysSoAndWhy() async throws {
        let (locations, work) = try temporary()
        let fresh = archived(work, daysAgo: 0.2), fresher = archived(work, daysAgo: 0.1)
        let core = try await core(locations, seeded: [fresh, fresher],
                                  settings: RetentionSettings(keepFor: .days30, cap: .gb1))
        await sized(core, [fresh.id: 800_000_000, fresher.id: 800_000_000])
        await core.checkRetention()
        #expect(await core.agent(fresh.id) != nil)
        let state = await core.retentionState()
        #expect(state.overCap == OverCap(bytesOver: 600_000_000, holding: [.firstDay: 2]))
    }

    @Test func liveAgentsNeverCountTowardTheCap() async throws {
        let (locations, work) = try temporary()
        let live = Agent(runtimeID: "claude", cwd: work, title: "live", state: .finished, endedReason: .endTurn)
        let small = archived(work, daysAgo: 5)
        let core = try await core(locations, seeded: [live, small],
                                  settings: RetentionSettings(keepFor: .days30, cap: .gb1))
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

    @Test func aChangeThatWouldRetireAgentsIsDescribedBeforeItIsApplied() async throws {
        let (locations, work) = try temporary()
        let agents = [archived(work, daysAgo: 10), archived(work, daysAgo: 11), archived(work, daysAgo: 12)]
        let core = try await core(locations, seeded: agents)
        await sized(core, Dictionary(uniqueKeysWithValues: agents.map { ($0.id, 1_000) }))

        let asked = await set(core, RetentionSettings(keepFor: .days7), confirmed: false)
        #expect(!asked.applied)
        #expect(asked.wouldRetire == DaemonAPI.RetirePreview(count: 3, bytes: 3_000))
        #expect(await core.retentionState().settings.keepFor == .days30)
        for agent in agents { #expect(await core.agent(agent.id) != nil) }

        let done = await set(core, RetentionSettings(keepFor: .days7), confirmed: true)
        #expect(done.applied)
        #expect(done.state?.retiredCount == 3)
        for agent in agents { #expect(await core.agent(agent.id) == nil) }
    }

    @Test func aChangeThatRetiresNothingIsAppliedAtOnce() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, seeded: [archived(work, daysAgo: 3)])
        let result = await set(core, RetentionSettings(keepFor: .days14, cap: .gb5), confirmed: false)
        #expect(result.applied)
        #expect(await core.retentionState().settings == RetentionSettings(keepFor: .days14, cap: .gb5))
    }

    @Test func foreverWithNoLimitKeepsEverythingAndSurvivesARestart() async throws {
        let (locations, work) = try temporary()
        let ancient = archived(work, daysAgo: 400)
        let core = try await core(locations, seeded: [ancient])
        await sized(core, [ancient.id: 50_000_000_000])
        _ = await set(core, RetentionSettings(keepFor: .forever, cap: .none), confirmed: true)
        #expect(await core.agent(ancient.id) != nil)

        let again = try await self.core(locations)
        await again.checkRetention()
        #expect(await again.agent(ancient.id) != nil)
        #expect(await again.retentionState().settings.isOff)
    }

    @Test func onlyThePersonsWindowMayChangeTheSettingsOrRetire() {
        for method in [DaemonAPI.Method.retentionSet, DaemonAPI.Method.agentsRetire] {
            #expect(ConnectionRole.control.allows(method))
            #expect(!ConnectionRole.device.allows(method))
            #expect(!ConnectionRole.agent.allows(method))
            #expect(!ConnectionRole.stranger.allows(method))
        }
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.retentionState))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.agentsRetired))
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
        #expect(await core.agent(agent.id)?.retirement == .held(.worktreeHasWork))

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
        await core.putRun(WorkflowRun(workflowID: "nightly", folder: work, trigger: .agentFinished, agentID: inRun.id))
        try await core.reportPresence(.init(watching: watched.id, active: true), from: .mac, connection: UUID())
        await core.checkRetention()
        #expect(await core.agent(inRun.id)?.retirement == .held(.workflowRunning))
        #expect(await core.agent(watched.id)?.retirement == .held(.openInWindow))

        await core.clearRuns()
        await core.checkRetention()
        #expect(await core.agent(inRun.id) == nil)
        #expect(await core.agent(watched.id) != nil)
    }

    // MARK: US4

    @Test func aRetirementWithinAWeekIsOnItsRow() async throws {
        let (locations, work) = try temporary()
        let soon = archived(work, daysAgo: 27)
        let core = try await core(locations, seeded: [soon])
        await core.checkRetention()
        #expect(await core.agent(soon.id)?.retirement == .at(soon.archivedAt!.addingTimeInterval(30 * day)))
    }

    @Test func unarchivingBringsItBackWholeAndWithoutANote() async throws {
        let (locations, work) = try temporary()
        var soon = archived(work, daysAgo: 27)
        soon.availableCommands = [SlashCommand(name: "review", description: "Review the code")]
        let core = try await core(locations, seeded: [soon])
        await core.checkRetention()
        try await core.unarchive(soon.id)
        let back = await core.agent(soon.id)
        #expect(back?.retirement == nil && back?.archivedAt == nil)
        #expect(back?.availableCommands.map(\.name) == ["review"])
        #expect(try await core.transcript(.init(agentID: soon.id)).entries.isEmpty == false)
    }

    @Test func aBranchKeepsItsOwnConversationWhenTheOriginalIsRetired() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.sessionCapabilities = ["close": [:], "list": [:], "fork": [:]]
        var original = archived(work, daysAgo: 40)
        original.runtimeSessionID = "session-1"
        let core = try await core(locations, seeded: [original],
                                  settings: RetentionSettings(keepFor: .forever, cap: .none),
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

    // MARK: US7

    @Test func retireNowSaysWhatItFreesThenRetiresWhenConfirmed() async throws {
        let (locations, work) = try temporary()
        let recent = archived(work, daysAgo: 0.1)
        let core = try await core(locations, seeded: [recent])
        await sized(core, [recent.id: 5_400_000])
        let asked = try await core.retireNow(.init(agentID: recent.id, confirmed: false))
        #expect(asked == DaemonAPI.RetirePreview(count: 1, bytes: 5_400_000))
        #expect(await core.agent(recent.id) != nil)
        _ = try await core.retireNow(.init(agentID: recent.id, confirmed: true))
        #expect(await core.agent(recent.id) == nil)
        #expect(await core.retiredTombstones(.init(ids: [recent.id])).first?.retiredBecause == .person)
    }

    @Test func retireNowIsRefusedForALiveAgentAHeldOneAndARetiredOne() async throws {
        let (locations, work) = try temporary()
        let live = Agent(runtimeID: "claude", cwd: work, title: "live", state: .finished, endedReason: .endTurn)
        let held = archived(work, daysAgo: 3)
        let core = try await core(locations, seeded: [live, held])
        await core.putRun(WorkflowRun(workflowID: "nightly", folder: work, trigger: .agentFinished, agentID: held.id))

        await #expect(throws: JSONRPCError.self) { _ = try await core.retireNow(.init(agentID: live.id, confirmed: true)) }
        do {
            _ = try await core.retireNow(.init(agentID: held.id, confirmed: true))
            Issue.record("a held agent was retired")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.retireRefused)
            #expect(error.message == RetirementWords.refusal(.workflowRunning))
        }
        await core.clearRuns()
        _ = try await core.retireNow(.init(agentID: held.id, confirmed: true))
        do {
            _ = try await core.retireNow(.init(agentID: held.id, confirmed: true))
            Issue.record("retired twice")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.agentRetired)
        }
    }

    @Test func retireNowIsNotStoppedByTheWindowThatAsked() async throws {
        let (locations, work) = try temporary()
        let open = archived(work, daysAgo: 3)
        let core = try await core(locations, seeded: [open])
        try await core.reportPresence(.init(watching: open.id, active: true), from: .mac, connection: UUID())
        _ = try await core.retireNow(.init(agentID: open.id, confirmed: true))
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
