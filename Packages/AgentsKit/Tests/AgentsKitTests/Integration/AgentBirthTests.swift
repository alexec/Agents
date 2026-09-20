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
        // The shape of the whole thing, named so a regression reads clearly rather than
        // as an arithmetic failure.
        #expect(beforeAnyEnding.map(\.state) == [.starting, .running])
    }

    /// SC-002 against the file rather than the wire. A daemon killed at this instant
    /// must leave something true behind.
    @Test func theRecordWrittenAtBirthCarriesNoEnding() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        let data = try Data(contentsOf: locations.record(id))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["state"] as? String == "starting")
        #expect(json["endedReason"] == nil, "a record claiming an ending it never had")
        #expect(json["archivedReason"] == nil)
    }

    /// The spec's "stopping an agent that is starting" edge case.
    ///
    /// Reachable precisely because `starting` answers true to `holdsRuntime`, which is
    /// what lets `stop` act on an agent whose first turn has not begun.
    @Test func stoppingAnAgentBeforeItsFirstTurn() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(500)
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        try await core.stop(id)

        let agent = try #require(await core.agent(id))
        #expect(agent.state == .stopped)
        #expect(agent.endedReason == .cancelled, "their doing, and said to be theirs")
        #expect(agent.isConsistent)
        // The runtime it was holding is let go rather than left running unowned.
        #expect(await core.isHoldingAgents == false)
    }

    /// FR-004, through the daemon rather than through the table.
    ///
    /// `starting` answering true to `hasTurnInFlight` is the whole mechanism: `enqueue`
    /// reads it and puts the words on the queue instead of starting a second turn.
    @Test func aPromptArrivingDuringAStartQueuesRatherThanRacing() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "first"))
        try await core.prompt(.init(agentID: id, text: "second"))

        // Whatever the first turn is doing, the second prompt has not begun a turn of
        // its own — it is either still queued or has drained behind the first.
        await eventually("both turns went, in order") { () async -> Bool in
            guard let agent = await core.agent(id) else { return false }
            return agent.queuedPrompts.isEmpty && agent.state == .finished
        }
        let entries = try await core.store.transcript(for: id, limit: 200).entries
        // Only what the person said. The app asks a silent agent how its turn went
        // (014), and that prompt is in the transcript too — it is not something anybody
        // typed, and it is not what this test is about.
        let said = entries.compactMap { entry -> String? in
            guard case .userMessage(let text, _, let from) = entry.kind, from == .person
            else { return nil }
            return text
        }
        #expect(said == ["first", "second"], "the order they were typed in")
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
