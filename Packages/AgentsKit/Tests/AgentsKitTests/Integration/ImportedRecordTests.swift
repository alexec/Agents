import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// #228: a scratch daemon whose root had been seeded with copies of the real root's
/// records picked the live ones back up, in the real folders, with the real sessions.
///
/// Every record here is synthetic, made by the test. None is copied from a real root.
@Suite("Records from another root", .timeLimit(.minutes(1)))
struct ImportedRecordTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsImportedTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations, locks: URL? = nil) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: launcher)
        if let locks { await core.setSessionLocks(locks) }
        return core
    }

    /// What `Daemon.start` does with a record, short of the socket.
    private func start(_ core: DaemonCore) async {
        await core.holdWorkflowEventsUntilStarted()
        let recovered = await core.recover()
        await core.startWorkflows()
        await core.pickUpAfterRestart(recovered)
        await core.resumeBlocksAfterRestart()
        await core.resumeEventWaitsAfterRestart()
    }

    /// A working one, a blocked one with a wake queued and never sent, and a waiting one,
    /// each stamped with a root that is not this one.
    private func seedCopies(_ store: AgentStore, in work: URL, stamp: String?) async throws -> [Agent] {
        var working = Agent(runtimeID: "claude", cwd: work, state: .running, runtimeSessionID: "copied-working")
        working.madeInRoot = stamp
        let wake = QueuedPrompt(text: "(Your wait for custom.ping is over.)", from: .app)
        var blocked = Agent(runtimeID: "claude", cwd: work, state: .finished, runtimeSessionID: "copied-blocked",
                            endedReason: .endTurn)
        blocked.queuedPrompts = [wake]
        blocked.eventWait = EventWait(patterns: [], from: 0, since: Date().addingTimeInterval(-60),
                                      ending: .timedOut, resumePromptID: wake.id)
        blocked.madeInRoot = stamp
        var waiting = Agent(runtimeID: "claude", cwd: work, state: .waitingOnUser, runtimeSessionID: "copied-waiting")
        waiting.madeInRoot = stamp
        for agent in [working, blocked, waiting] { try await store.save(agent) }
        return [working, blocked, waiting]
    }

    @Test func copiedRecordsAreShownStoppedAndNeverRun() async throws {
        let (locations, work) = try temporary()
        let copies = try await seedCopies(try AgentStore(locations: locations), in: work, stamp: "another-root")
        let launcher = FakeLauncher()
        let core = try await core(launcher, locations: locations)

        await start(core)
        try await Task.sleep(for: .milliseconds(300))  // time passing is the assertion

        #expect(launcher.launchCount == 0, "no runtime started for a copy")
        #expect(await core.stillResuming().isEmpty)
        for copy in copies {
            let now = await core.agent(copy.id)
            #expect(now?.state == .stopped)
            #expect(now?.endedReason == .imported)
            #expect(now?.eventWait == nil, "no wait left to wake it")
            #expect(now?.madeInRoot == "another-root", "and it keeps the stamp it came with")
            #expect(now?.isConsistent == true)
        }
        // On disk too, so the next start says the same without saying it again.
        let reread = try await AgentStore(locations: locations).load(copies.map(\.id)).agents
        #expect(reread.allSatisfy { $0.endedReason == .imported })

        // A person's prompt is refused, not queued.
        await #expect(throws: JSONRPCError.self) {
            try await core.prompt(.init(agentID: copies[0].id, text: "carry on"))
        }
        #expect(await core.agent(copies[0].id)?.queuedPrompts.isEmpty == true)
        #expect(launcher.launchCount == 0)

        // And a second start leaves them exactly as they are.
        let again = try await self.core(launcher, locations: locations)
        await start(again)
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launchCount == 0)
        let notes = try await again.transcript(.init(agentID: copies[0].id, before: nil, limit: 100)).entries
            .filter { $0.text == RuntimeNote.imported }
        #expect(notes.count == 1, "said once")
    }

    /// The first start after stamps came in adopts what is already there, once.
    @Test func unstampedRecordsAreAdoptedOnlyAtTheFirstStart() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let own = Agent(runtimeID: "claude", cwd: work, state: .running, runtimeSessionID: "own")
        try await store.save(own)
        let launcher = FakeLauncher()
        let first = try await core(launcher, locations: locations)
        await start(first)
        await eventually("its own agent is picked up") { launcher.launchCount >= 1 }
        let rootID = await first.rootID
        #expect(rootID != nil)
        #expect(await first.agent(own.id)?.madeInRoot == rootID)

        // Copied in later, with no stamp: not this root's, since this root already had one.
        let later = try await seedCopies(store, in: work, stamp: nil)
        let secondLauncher = FakeLauncher()
        let second = try await core(secondLauncher, locations: locations)
        await start(second)
        try await Task.sleep(for: .milliseconds(300))
        #expect(secondLauncher.launchCount == 0, "nothing started for the copies")
        for copy in later { #expect(await second.agent(copy.id)?.endedReason == .imported) }
        #expect(await second.rootID == rootID, "the same root keeps its id")
    }

    /// A whole root copied elsewhere is a new root, and what it holds is imported.
    @Test func aRootCopiedWholeIsANewRoot() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let own = Agent(runtimeID: "claude", cwd: work, state: .finished, runtimeSessionID: "own",
                        endedReason: .endTurn)
        try await store.save(own)
        let first = try await core(FakeLauncher(), locations: locations)
        _ = await first.recover()

        let copyRoot = locations.root.deletingLastPathComponent()
            .appendingPathComponent("AgentsImportedCopy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: locations.root, to: copyRoot)
        defer { try? FileManager.default.removeItem(at: copyRoot) }
        let copied = StoreLocations(root: copyRoot)
        let launcher = FakeLauncher()
        let copy = try await core(launcher, locations: copied)
        await start(copy)
        #expect(await copy.rootID != (await first.rootID))
        #expect(await copy.agent(own.id)?.endedReason == .imported)
        await #expect(throws: JSONRPCError.self) {
            try await copy.prompt(.init(agentID: own.id, text: "go"))
        }
        #expect(launcher.launchCount == 0)
    }

    /// Two daemons, one conversation: the second is refused while the first holds it,
    /// and may take it once the first lets go.
    @Test func aSessionLiveUnderAnotherDaemonIsNotResumed() async throws {
        let (first, work) = try temporary()
        let (second, otherWork) = try temporary()
        let locks = first.root.deletingLastPathComponent()
            .appendingPathComponent("AgentsSessionLocks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: locks) }

        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(3)
        let holder = try await core(FakeLauncher(script: script), locations: first, locks: locks)
        _ = await holder.recover()
        let id = try await holder.start(.init(runtimeID: "claude", cwd: work, prompt: "long job"))
        await eventually("it is working") { await holder.agent(id)?.state == .running }
        let sessionID = try #require(await holder.agent(id)?.runtimeSessionID)

        // The same conversation, recorded by a second daemon as its own and working.
        let store = try AgentStore(locations: second)
        let other = try await core(FakeLauncher(), locations: second, locks: locks)
        _ = await other.recover()
        var twin = Agent(runtimeID: "claude", cwd: otherWork, state: .finished, runtimeSessionID: sessionID,
                         endedReason: .endTurn)
        twin.madeInRoot = await other.rootID
        try await store.save(twin)
        let launcher = FakeLauncher()
        let again = try await core(launcher, locations: second, locks: locks)
        _ = await again.recover()

        await #expect(throws: JSONRPCError.self) {
            try await again.prompt(.init(agentID: twin.id, text: "go"))
        }
        #expect(launcher.launchCount == 0, "refused before a runtime started")
        #expect(await again.sessionClaims.holds(twin.id) == false)

        // Let go by the holder, it is free.
        try await holder.stop(id)
        await eventually("the holder let go") { await holder.sessionClaims.holds(id) == false }
        try await again.prompt(.init(agentID: twin.id, text: "go"))
        await eventually("now it runs") { launcher.launchCount == 1 }
    }

    /// A scratch daemon kept to its root (#228, optional).
    @Test func aConfinedDaemonRefusesFoldersOutsideItsRoot() async throws {
        let (locations, work) = try temporary()
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let launcher = FakeLauncher()
        let core = try await core(launcher, locations: locations)
        await core.setConfinedTo(locations.root)
        _ = await core.recover()

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.start(.init(runtimeID: "claude", cwd: outside, prompt: "go"))
        }
        #expect(launcher.launchCount == 0)
        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        #expect(launcher.launchCount >= 1, "inside its root it runs as ever")
    }
}
