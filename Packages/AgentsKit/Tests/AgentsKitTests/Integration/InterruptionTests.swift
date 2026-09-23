import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What happens when something arrives in the middle of something else: a stop while a
/// runtime is starting, a runtime dying with a form open, a daemon dying mid-line. Each
/// of these used to leave the record saying one thing and the agent doing another.
@Suite("Interruptions", .timeLimit(.minutes(1)))
struct InterruptionTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsInterruptionTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    private func letGo(_ core: DaemonCore, _ id: UUID) async {
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        await eventually("its runtime was handed back") { await core.live[id] == nil }
    }

    // MARK: Stop while starting

    /// Stop found nothing to cancel — no runtime yet, no turn — and the start that
    /// was already on its way went on to begin the turn anyway.
    @Test func aStopWhileTheRuntimeStartsIsHeard() async throws {
        let (locations, work) = try temporary()
        var slow = FakeACPAgent.Script()
        slow.handshakeDelay = .milliseconds(500)
        let launcher = FakeLauncher(script: slow, then: [.init()])
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "first"))
        await letGo(core, id)

        // On its own task, as a window's request is: `prompt` waits for the start,
        // and the stop has to be able to arrive while it does.
        Task { try await core.prompt(.init(agentID: id, text: "second")) }
        await eventually("the runtime is on its way") { launcher.launchCount == 2 }
        try await core.stop(id)

        // Longer than the handshake: time passing is the assertion.
        try await Task.sleep(for: .milliseconds(900))
        let agent = await core.agent(id)
        #expect(agent?.state.holdsRuntime == false, "no turn began after the stop")
        #expect(agent?.queuedPrompts.map(\.text) == ["second"], "and the words are still waiting")
        #expect(await core.live[id] == nil, "and the runtime went back")
        let received = await launcher.lastAgent?.received ?? []
        #expect(!received.contains(ACP.Method.prompt), "nothing was sent to it: \(received)")
    }

    // MARK: A runtime dying

    @Test func aFormDiesWithTheRuntimeThatAskedIt() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation,
                                  ["mode": "form", "message": "Which branch?",
                                   "requestedSchema": ["properties": ["branch": ["type": "string"]]]])]
        let launcher = FakeLauncher(script: script,
                                    capabilities: .init(elicitationForm: true, elicitationURL: true))
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the form is held") { await !core.pendingElicitations().isEmpty }

        await core.live[id]?.noteExit(status: 9)

        await eventually("and goes with the runtime") { await core.pendingElicitations().isEmpty }
    }

    // MARK: Branching

    @Test func aBranchIsANewAgentNotACopyOfTheRecord() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.sessionCapabilities = ["close": [:], "list": [:], "fork": [:]]
        script.turnDelay = .seconds(2)
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "long job"))
        await eventually("it is working") { await core.agent(id)?.state == .running }
        try await core.prompt(.init(agentID: id, text: "and then this"))

        let branch = try await core.fork(agentID: id)
        let copy = await core.agent(branch)
        #expect(copy?.state == .finished, "settled, not running with no runtime behind it")
        #expect(copy?.isConsistent == true)
        #expect(copy?.queuedPrompts.isEmpty == true, "the original's queue is the original's")
        #expect(copy?.costToDate.isEmpty == true, "and so is what it spent")
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["and then this"])
    }

    // MARK: Money

    @Test func aPerAgentLimitOfNothingStopsANewAgent() async throws {
        let (locations, work) = try temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try LimitStore(locations: locations).save(CostLimits(perAgent: Cost(amount: 0, currency: "USD")))
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        }
        #expect(launcher.launchCount == 0, "refused before a runtime was spent on it")
    }

    /// Each process quotes its spend as a running total that starts at nothing. The
    /// last figure was kept across processes, so the next one's reading was banked only
    /// for what it exceeded the last — here, nothing at all.
    @Test func eachNewProcessIsCountedFromNothing() async throws {
        let (locations, work) = try temporary()
        var costing = FakeACPAgent.Script()
        costing.updates = [["sessionUpdate": "usage_update", "used": 10, "size": 100,
                            "cost": ["amount": 0.5, "currency": "USD"]]]
        let launcher = FakeLauncher(script: costing)
        let core = try core(launcher, locations: locations)

        // The first turn, and the question after it about how it went: two turns,
        // each in a process of its own.
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("0.5 in each of two processes") {
            await core.agent(id)?.costToDate["USD"] == 1.0
        }
        #expect(launcher.launchCount == 2)
    }

    // MARK: Picking up after a restart

    /// Held by a limit, the words about this minute were left at the front of the
    /// queue and told the agent the app had "just" restarted a day later.
    @Test func wordsAboutARestartAreNotKeptWhenALimitHoldsThem() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let agent = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s",
                          costToDate: ["USD": 5])
        try await store.save(agent)
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try LimitStore(locations: locations).save(CostLimits(perAgent: Cost(amount: 1, currency: "USD")))

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await eventually("the pick-up is over") { await core.stillResuming().isEmpty }
        #expect(await core.agent(agent.id)?.queuedPrompts.isEmpty == true,
                "nothing about the restart is left waiting to go later")
        #expect(launcher.launchCount == 0)
    }

    // MARK: The record

    @Test func aHalfWrittenLineDoesNotSwallowTheNext() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let agent = Agent(runtimeID: "grok", cwd: work, state: .finished, endedReason: .endTurn)
        try await store.save(agent)
        try await store.append(TranscriptEntry(kind: .runtimeNote("before")), for: agent.id)
        await store.closeTranscript(for: agent.id)

        // What a daemon killed mid-write leaves: a line with no end.
        let handle = try FileHandle(forWritingTo: locations.transcript(agent.id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"kind\":{\"runtimeNo".utf8))
        try handle.close()

        let reopened = try AgentStore(locations: locations)
        try await reopened.append(TranscriptEntry(kind: .runtimeNote("after")), for: agent.id)
        let page = try await reopened.transcript(for: agent.id)
        #expect(page.entries.compactMap(\.text) == ["before", "after"])
    }

    @Test func anEndingFromANewerBuildDoesNotLoseTheAgent() throws {
        let agent = Agent(runtimeID: "grok", cwd: URL(fileURLWithPath: "/tmp"),
                          state: .stopped, endedReason: .maxTokens)
        let written = try StoreCoding.encoder.encode(agent)
        var object = try JSONDecoder().decode(JSONValue.self, from: written).objectValue ?? [:]
        object["endedReason"] = "somethingNew"
        object["archivedReason"] = "bySomethingNew"
        let data = try JSONEncoder().encode(JSONValue.object(object))
        let read = try StoreCoding.decoder.decode(Agent.self, from: data)
        #expect(read.id == agent.id)
        #expect(read.endedReason == .unrecognised)
        #expect(read.archivedReason == .byUser)
    }

    @Test func anUnreadableLimitsFileIsKeptNotWrittenOver() throws {
        let (locations, _) = try temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: locations.limits)

        let limits = LimitStore(locations: locations)
        #expect(limits.load().isEmpty)
        try limits.save(CostLimits(daily: Cost(amount: 3, currency: "USD")))

        let kept = try FileManager.default.contentsOfDirectory(atPath: locations.root.path)
            .filter { $0.hasPrefix(locations.limits.lastPathComponent + ".unreadable-") }
        #expect(kept.count == 1, "what was there is set aside, not lost")
    }
}
