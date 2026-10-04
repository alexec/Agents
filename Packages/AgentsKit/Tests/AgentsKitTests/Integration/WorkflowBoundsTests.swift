import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the workflow and event layers write and read while nothing much happens (#218):
/// `workflows.json` only on a real change, a workflow file read only when it changed,
/// `events-state.json` only when it changed, and nothing kept for ever about what has gone.
@Suite("Workflow and event bounds", .timeLimit(.minutes(1)))
struct WorkflowBoundsTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsBounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func write(_ prompt: String, as workflowID: String, in project: URL) throws {
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        try Data("""
            ---
            on:
              - schedule:
                  at: [":00"]
            agent: new
            ---

            \(prompt)
            """.utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations, clock: Clock) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(), now: { clock.now })
        await core.loadFromDisk()
        return core
    }

    // MARK: workflows.json

    /// Five idle minutes of ticks write the heartbeat twice a minute, not four times.
    @Test func idleTicksWriteTheHeartbeatTwiceAMinute() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("Run the tests.", as: "tests", in: work)
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        // Off the hour, so nothing comes due.
        var tick = Date(timeIntervalSince1970: 1_800_000_000 + 60)
        await core.tickWorkflows(now: tick)
        let before = await core.workflowStore.writes
        for _ in 0..<20 {
            tick = tick.addingTimeInterval(15)
            await core.tickWorkflows(now: tick)
        }
        let written = await core.workflowStore.writes - before
        #expect(written >= 9 && written <= 11, "\(written) writes in five minutes of ticks")
        // And what a restart reads is at most half a minute old.
        let onDisk = try #require(WorkflowStore(locations: locations).load().lastTickAt)
        #expect(tick.timeIntervalSince(onDisk) < WorkflowStore.tickWriteInterval)
        #expect(await core.workflowStore.load().lastTickAt == tick, "the daemon itself has the latest")
    }

    /// A save of what the file already holds writes nothing; a change is written.
    @Test func aSaveOfTheSameRecordsWritesNothing() throws {
        let (locations, _) = try temporary()
        let store = WorkflowStore(locations: locations)
        var records = WorkflowRecords()
        records.update(folder: URL(filePath: "/tmp/somewhere/api"), workflowID: "nightly") { $0.approvedDigest = "abc" }
        try store.save(records)
        let modified = try FileManager.default.attributesOfItem(atPath: locations.workflows.path)[.modificationDate] as? Date
        try store.save(store.load())
        try store.save(records)
        #expect(store.writes == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: locations.workflows.path)[.modificationDate] as? Date
                == modified)
        records.update(folder: URL(filePath: "/tmp/somewhere/api"), workflowID: "nightly") { $0.approvedDigest = "def" }
        try store.save(records)
        #expect(store.writes == 2)
    }

    /// Held in memory, but a file written by anybody else is read afresh.
    @Test func aFileWrittenByAnotherIsReadAgain() throws {
        let (locations, _) = try temporary()
        let store = WorkflowStore(locations: locations)
        var records = WorkflowRecords()
        records.update(folder: URL(filePath: "/tmp/somewhere/api"), workflowID: "nightly") { $0.approvedDigest = "abc" }
        try store.save(records)
        #expect(store.load().states.first?.approvedDigest == "abc")

        var other = records
        other.update(folder: URL(filePath: "/tmp/somewhere/api"), workflowID: "nightly") { $0.approvedDigest = "xyz" }
        try WorkflowStore(locations: locations).save(other)
        #expect(store.load().states.first?.approvedDigest == "xyz")
    }

    // MARK: Digests

    /// Listing and firing read each workflow file once, until it changes; a file put back
    /// with its old modification date is still read again.
    @Test func aWorkflowFileIsHashedOnceUntilItChanges() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        for index in 0..<5 { try write("Workflow \(index).", as: "w\(index)", in: work) }
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        _ = await core.allWorkflows(in: work)
        let warm = await core.workflowDigestReads

        _ = await core.allWorkflows(in: work)
        let workflow = try #require(await core.workflows[work]?["w0"])
        await core.fire(workflow, on: .schedule(WorkflowSchedule()))
        #expect(await core.workflowDigestReads == warm, "nothing changed, so nothing was read")

        // The same size, and the old date put back by hand: still a new file.
        let url = WorkflowFile.url(for: "w1", in: work)
        let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try write("Workflow X.", as: "w1", in: work)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        await core.rescanWorkflows(in: work)
        let summary = try #require(await core.allWorkflows(in: work).first { $0.workflowID == "w1" })
        #expect(summary.awaitingApproval != nil, "a changed file waits, whatever its date says")
        #expect(await core.workflowDigestReads == warm + 1)
    }

    // MARK: Pruning

    /// The state of a workflow whose file has gone is marked, kept for a while in case it
    /// comes back, and let go after `goneKept`.
    @Test func aDeletedWorkflowsStateIsLetGoAfterAMonth() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("Stays.", as: "stays", in: work)
        try write("Goes.", as: "goes", in: work)
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        #expect(await core.workflowStore.load().states.count == 2)

        try FileManager.default.removeItem(at: WorkflowFile.url(for: "goes", in: work))
        await core.rescanWorkflows(in: work)
        let marked = await core.workflowStore.load().state(folder: work, workflowID: "goes")
        #expect(marked?.goneSince == clock.now)
        #expect(marked?.approvedDigest != nil, "kept while it may come back")

        clock.advance(seconds: WorkflowRecords.goneKept + 60)
        await core.pruneWorkflowStates()
        let states = await core.workflowStore.load().states
        #expect(states.map(\.workflowID) == ["stays"])
        #expect(states.first?.goneSince == nil)
    }

    /// A file that comes back inside the month keeps its approval.
    @Test func aWorkflowThatComesBackKeepsItsState() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("Comes back.", as: "back", in: work)
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        let url = WorkflowFile.url(for: "back", in: work)
        let text = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        await core.rescanWorkflows(in: work)
        clock.advance(seconds: 7 * 24 * 60 * 60)
        try text.write(to: url)
        await core.rescanWorkflows(in: work)
        await core.pruneWorkflowStates()
        let state = await core.workflowStore.load().state(folder: work, workflowID: "back")
        #expect(state?.goneSince == nil)
        let summary = try #require(await core.allWorkflows(in: work).first { $0.workflowID == "back" })
        #expect(summary.awaitingApproval == nil)
    }

    // MARK: Events

    /// Positions are reserved a block at a time: a hundred events write the state twice,
    /// and a restart never hands out a position already given.
    @Test func eventsStateIsWrittenOncePerBlock() async throws {
        let (locations, _) = try temporary()
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.loadEventsIfNeeded()
        var last: EventPosition = 0
        for index in 0..<100 {
            clock.advance(seconds: 1)
            last = await core.raise(EventDraft(name: "custom.tick", at: clock.now, scope: .mac,
                                               sentence: "Tick \(index).", details: ["n": "\(index)"])).position
        }
        #expect(await core.eventStore.stateWrites == 2)

        let again = try await self.core(locations, clock: clock)
        clock.advance(seconds: 1)
        let next = await again.raise(EventDraft(name: "custom.tick", at: clock.now, scope: .mac,
                                                sentence: "After.", details: [:])).position
        #expect(next > last)
    }

    /// A source that saves the state mid-block keeps the block's end on disk, so a
    /// restart after a lost tail still never hands out a position already given.
    @Test func aSourcesSaveKeepsTheReservedBlock() async throws {
        let (locations, _) = try temporary()
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.loadEventsIfNeeded()
        var last: EventPosition = 0
        for index in 0..<10 {
            clock.advance(seconds: 1)
            last = await core.raise(EventDraft(name: "custom.tick", at: clock.now, scope: .mac,
                                               sentence: "Tick \(index).", details: [:])).position
        }
        await core.raiseCostLimit("daily", agent: nil)
        let onDisk = EventStore(locations: locations).loadState().nextPosition
        let reserved = await core.eventPositionsReserved
        #expect(onDisk >= reserved)
        #expect(onDisk > last + 2)
    }

    /// A repeat folded into one row is a line each time; the file is compacted before
    /// those lines outgrow the log.
    @Test func repeatLinesAreCompacted() async throws {
        let (locations, _) = try temporary()
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.loadEventsIfNeeded()
        let limit = EventLog.maximumEvents + DaemonCore.eventCapMargin
        for _ in 0...(limit + 1) {
            clock.advance(seconds: 1)
            await core.raise(EventDraft(name: "custom.same", at: clock.now, scope: .mac, sentence: "Same.", details: [:]))
        }
        let lines = try String(contentsOf: locations.events, encoding: .utf8).split(separator: "\n").count
        #expect(lines < 100, "\(lines) lines for one event")
        let read = EventStore(locations: locations).load()
        #expect(read.events.count == 1)
        #expect(read.events.first?.count == limit + 2)
    }

    /// The log is held to its maximum as it grows, not only on the hour.
    @Test func theLogIsCappedOnAppend() async throws {
        let (locations, _) = try temporary()
        let clock = Clock()
        let core = try await core(locations, clock: clock)
        await core.loadEventsIfNeeded()
        for index in 0...(EventLog.maximumEvents + DaemonCore.eventCapMargin) {
            await core.raise(EventDraft(name: "custom.n", at: clock.now, scope: .mac,
                                        sentence: "N.", details: ["n": "\(index)"]))
        }
        #expect(await core.eventLog.events.count == EventLog.maximumEvents)
    }

    // MARK: Walks

    /// Only live agents' branches are watched; an archived agent's are not (#218).
    @Test func onlyLiveAgentsBranchesAreWatched() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let store = try AgentStore(locations: locations)
        for (name, archived) in [("live", false), ("old", true)] {
            var agent = Agent(runtimeID: "claude", cwd: work.appendingPathComponent(".agents/worktrees/\(name)"),
                              title: name, state: archived ? .archived : .finished, endedReason: .endTurn,
                              archivedReason: archived ? .byUser : nil)
            agent.worktree = AgentWorktree(name: name, root: agent.cwd, branch: "agents/\(name)", project: work,
                                           base: "main", madeByApp: true)
            try await store.save(agent)
        }
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        #expect(await core.watchedBranches(in: work, tips: [:]) == ["main", "agents/live"])
    }

    /// Publishes past their hour and the tips of folders that are no longer projects go.
    @Test func eventStateForgetsWhatHasGone() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let clock = Clock()
        let store = try AgentStore(locations: locations)
        let agent = Agent(runtimeID: "claude", cwd: work, title: "Publisher", state: .finished, endedReason: .endTurn)
        try await store.save(agent)
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                              launcher: FakeLauncher(), now: { clock.now })
        await core.loadFromDisk()
        await core.bindAppToken("token", to: agent.id)
        _ = try await core.publishEvent(.init(token: "token", name: "custom.done", message: nil, details: nil))
        await core.setBranchTips(["/no/longer/a/project": ["main": "abc"], work.path: ["main": "def"]])
        clock.advance(seconds: 3601)
        await core.pruneEventState()
        let state = EventStore(locations: locations).loadState()
        #expect(state.publishes.isEmpty)
        #expect(Array(state.branchTips.keys) == [work.path])
    }
}

extension DaemonCore {
    /// For the tests: tips as if seen.
    func setBranchTips(_ tips: [String: [String: String]]) {
        loadEventsIfNeeded()
        eventState.branchTips = tips
    }
}
