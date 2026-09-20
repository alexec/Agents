import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent being born, and the group it is in while it is.
///
/// The claim this suite carries is the one a person sees with their own eyes and no
/// pure test can make: from the moment a new agent first reaches a window, it is under
/// **Working** and it carries no ending — not once, not for a frame. That is a property
/// of the *sequence* of `agents/changed` notifications rather than of any single value,
/// which is why it is here and against `FakeLauncher` rather than in a unit suite.
///
/// What it used to be: the record was written `stopped` with `endedReason: .endTurn`,
/// broadcast, and only then given its first turn — so a brand-new agent appeared under
/// **Stopped**, beside the ones the person had given up on, and jumped to **Working** a
/// moment later.
@Suite("An agent being born", .timeLimit(.minutes(1)))
struct AgentBirthTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsBirthTests-\(UUID().uuidString)", isDirectory: true)
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

    /// SC-001 and SC-002 together, because they are one observation.
    @Test func aNewAgentIsNeverInAGroupOtherThanWorking() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        // A turn that takes its time, so there is a real interval between the record
        // being written and the first turn ending — the window the flicker lived in.
        script.turnDelay = .milliseconds(200)
        let core = try core(FakeLauncher(script: script), locations: locations)

        let seen = SeenAgents()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.agentChanged,
                  let params,
                  let agent = try? JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(params))
            else { return }
            seen.append(agent)
        }

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }

        let broadcasts = seen.all.filter { $0.id == id }
        #expect(!broadcasts.isEmpty, "no broadcast was recorded, so this proved nothing")

        // Everything up to the agent's first ending. Deliberately not the whole
        // sequence: a turn ending cleanly is asked how it went (014), and that question
        // is a turn of its own, so broadcasts keep arriving afterwards. The claim here
        // is about the interval between an agent being made and its first ending, which
        // is where the flicker lived.
        let beforeAnyEnding = broadcasts.prefix { $0.state != .finished && $0.state != .stopped }
        #expect(beforeAnyEnding.count < broadcasts.count,
                "the turn never ended, so the window under test never closed")

        for (index, agent) in beforeAnyEnding.enumerated() {
            #expect(agent.group == .running,
                    "broadcast \(index) put a new agent under \(agent.group.title)")
            #expect(agent.endedReason == nil,
                    "broadcast \(index) carried \(String(describing: agent.endedReason))")
        }

        #expect(broadcasts.first?.state == .starting,
                "the first thing any window hears about a new agent is that it is starting")
        // The shape, asserted as the claim rather than as a count: it starts, it ends
        // up running, and it passes through nothing else on the way. How many
        // notifications each state takes is the daemon's business — the prompt coming
        // off the queue is one of them — and pinning it would make this test fail for
        // reasons that are not about the flicker.
        #expect(beforeAnyEnding.first?.state == .starting)
        #expect(beforeAnyEnding.last?.state == .running)
        #expect(Set(beforeAnyEnding.map(\.state)) == [.starting, .running])
    }

    /// SC-002 against the file rather than the wire: a daemon killed at any instant
    /// must leave something true behind.
    ///
    /// The state is deliberately *not* pinned to `starting`. The record is saved as
    /// `starting` and then rewritten as `running` a few hundred microseconds later by
    /// a detached `saveQuietly`, so any assertion on which of the two is on disk when
    /// the test looks is a coin toss. The claim that matters is the one that holds at
    /// every instant: it never says the agent ended.
    @Test func theRecordWrittenAtBirthCarriesNoEnding() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        let data = try Data(contentsOf: locations.record(id))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(["starting", "running"].contains(json["state"] as? String ?? ""),
                "a new agent was written to disk as \(json["state"] ?? "nothing")")
        #expect(json["endedReason"] == nil, "a record claiming an ending it never had")
        #expect(json["archivedReason"] == nil)
    }

    /// And the birth shape itself, with no daemon and no timing in it at all: what
    /// `save` would write for an agent the moment it is made.
    @Test func theShapeOfANewRecordHasNoEndingInIt() throws {
        let agent = Agent(runtimeID: "grok", cwd: URL(filePath: "/tmp"), title: "new")
        let json = try #require(try JSONSerialization.jsonObject(
            with: try StoreCoding.encoder.encode(agent)) as? [String: Any])

        #expect(json["state"] as? String == "starting")
        #expect(json["endedReason"] == nil)
        #expect(json["archivedReason"] == nil)
        #expect(agent.isConsistent)
    }

    // MARK: An agent that really is `starting`
    //
    // `core.start(...)` does not return until `beginTurn` has awaited
    // `move(.turnBegun)`, so by the time a test holds the id the agent is already
    // `.running`. Racing the window between the record being saved and the first turn
    // is not a test, it is a coin toss — and a green coin toss is worse than no test.
    //
    // A `.starting` record on disk is the deterministic way in: `Agent.init` defaults
    // to it, the store accepts it because it is consistent, and `loadFromDisk` opens
    // it exactly as a daemon coming back would. That is also not a hypothetical
    // shape — it is precisely what a daemon killed mid-start leaves behind.

    private func seedStarting(in work: URL, _ store: AgentStore,
                              queued: [QueuedPrompt] = []) async throws -> Agent {
        let agent = Agent(runtimeID: "grok", cwd: work, title: "made, not yet begun",
                          queuedPrompts: queued)
        #expect(agent.state == .starting)
        try await store.save(agent)
        return agent
    }

    /// The spec's "stopping an agent that is starting" edge case.
    ///
    /// Reachable precisely because `starting` answers true to `holdsRuntime`, which is
    /// what lets `stop` act on an agent whose first turn has not begun.
    @Test func stoppingAnAgentBeforeItsFirstTurn() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let agent = try await seedStarting(in: work, store)
        let core = try core(FakeLauncher(), locations: locations)
        await core.loadFromDisk()
        #expect(await core.agent(agent.id)?.state == .starting, "the test never reached the state it is about")

        try await core.stop(agent.id)

        let stopped = try #require(await core.agent(agent.id))
        #expect(stopped.state == .stopped)
        #expect(stopped.endedReason == .cancelled, "their doing, and said to be theirs")
        #expect(stopped.isConsistent)
        #expect(await core.isHoldingAgents == false, "nothing is left claiming a runtime")
    }

    /// FR-004, through the daemon rather than through the table.
    ///
    /// `starting` answering true to `hasTurnInFlight` is the whole mechanism: `enqueue`
    /// reads it and puts the words on the queue instead of beginning a second turn.
    @Test func aPromptArrivingDuringAStartQueuesRatherThanRacing() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let agent = try await seedStarting(in: work, store)
        let core = try core(FakeLauncher(), locations: locations)
        await core.loadFromDisk()

        try await core.prompt(.init(agentID: agent.id, text: "while you are starting"))

        let after = try #require(await core.agent(agent.id))
        #expect(after.state == .starting, "the prompt began a turn it had no business beginning")
        #expect(after.queuedPrompts.map(\.text) == ["while you are starting"])
        // And nothing went to a runtime: no turn, so no user message on the record.
        let entries = try await core.store.transcript(for: agent.id, limit: 200).entries
        #expect(entries.contains { if case .userMessage = $0.kind { return true } else { return false } } == false)
    }

    /// The prompt outlives the daemon that was making the agent.
    ///
    /// The window is real and narrow: the record is saved before `beginTurn` writes
    /// anything, so a daemon killed there once lost what the person typed entirely —
    /// only its first eighty characters survived, as the title. The next daemon then
    /// picked the agent up and spent a turn telling it there was no history and to
    /// "start the work from here", with no work. Keeping the prompt on the queue from
    /// the agent's first moment is what makes that survivable.
    @Test func aPromptSurvivesADaemonKilledWhileTheAgentWasBeingMade() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let agent = try await seedStarting(in: work, store,
                                           queued: [QueuedPrompt(text: "do the thing")])
        let core = try core(FakeLauncher(), locations: locations)

        let recovered = await core.recover()
        #expect(recovered == [agent.id], "an agent found starting is one that was cut off")
        #expect(await core.agent(agent.id)?.endedReason == .daemonGone)

        await core.pickUpAfterRestart(recovered)
        await eventually("it was picked back up and did the work it was asked for") {
            guard let a = await core.agent(agent.id) else { return false }
            return a.state == .finished || a.state == .running
        }

        let entries = try await core.store.transcript(for: agent.id, limit: 200).entries
        let said = entries.compactMap { entry -> String? in
            if case .userMessage(let text, _, _) = entry.kind { return text }
            return nil
        }
        #expect(said.first == "do the thing", "the words the person typed reached the runtime")
        // And it was not told about a restart it has no history of.
        #expect(said.contains { $0.contains("The app restarted") } == false,
                "an agent with no conversation was given a note about one")
    }

    /// The other half: a `starting` record written before the prompt was queued — by a
    /// build predating this fix — still gets told something rather than nothing.
    @Test func aStartingRecordWithNothingQueuedIsStillExplained() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let agent = try await seedStarting(in: work, store)
        let core = try core(FakeLauncher(), locations: locations)

        let recovered = await core.recover()
        await core.pickUpAfterRestart(recovered)
        await eventually("it was told why it is starting from nothing") {
            let entries = (try? await core.store.transcript(for: agent.id, limit: 200).entries) ?? []
            return entries.contains { ($0.text ?? "").contains("before this conversation had begun") }
        }
    }

}

/// What the windows were told, in the order they were told it. `setBroadcaster` is
/// called from whatever context the daemon happens to be on, so this needs its own lock.
private final class SeenAgents: @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [Agent] = []

    func append(_ agent: Agent) {
        lock.lock(); defer { lock.unlock() }
        agents.append(agent)
    }

    var all: [Agent] {
        lock.lock(); defer { lock.unlock() }
        return agents
    }
}
