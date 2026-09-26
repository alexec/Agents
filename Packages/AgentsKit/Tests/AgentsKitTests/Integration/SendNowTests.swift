import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Send now: a queued prompt put into the running turn with `_session/steering`, where
/// the runtime advertised it, and the ordinary queue everywhere it did not work.
@Suite("Send now", .timeLimit(.minutes(1)))
struct SendNowTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSendNowTests-\(UUID().uuidString)", isDirectory: true)
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

    /// The person's words only: the app's own question after a turn is a message too.
    private func said(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry -> String? in
            if case .userMessage(let text, _, .person) = entry.kind { return text }
            return nil
        }
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry -> String? in
            if case .runtimeNote(let text) = entry.kind { return text }
            return nil
        }
    }

    /// A turn held open by `gate`, with "and also this" queued behind it.
    private func queuedBehindATurn(steering: String?, gate: TurnGate,
                                   permission: JSONValue? = nil)
        async throws -> (DaemonCore, FakeLauncher, UUID, QueuedPrompt) {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.steering = steering
        script.gate = gate
        script.permission = permission
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "first"))
        await eventually("the turn is under way") {
            if permission != nil { return await !core.pendingPermissionRequests().isEmpty }
            return gate.turnsArrived == 1
        }
        try await core.prompt(.init(agentID: id, text: "and also this"))
        let queued = try #require(await core.agent(id)?.queuedPrompts.first)
        return (core, launcher, id, queued)
    }

    @Test func theAdvertisedCapabilityIsReadOffTheHandshake() async throws {
        let gate = TurnGate()
        let (core, _, _, _) = try await queuedBehindATurn(steering: "injected", gate: gate)
        #expect(await core.accounts["claude"]?.canSteer == true)
        gate.open()

        let plain = TurnGate()
        let (other, _, _, _) = try await queuedBehindATurn(steering: nil, gate: plain)
        #expect(await other.accounts["claude"]?.canSteer == false, "keyed on what it said, not on its name")
        plain.open()
    }

    @Test func injectedWordsJoinTheTurnAndLeaveTheQueue() async throws {
        let gate = TurnGate()
        let (core, launcher, id, queued) = try await queuedBehindATurn(steering: "injected", gate: gate)

        try await core.sendNow(.init(agentID: id, promptID: queued.id))

        let agent = try #require(launcher.lastAgent)
        let steer = try #require(await agent.steers.first)
        #expect(steer["prompt"]?.arrayValue?.first?["text"]?.stringValue == "and also this")
        #expect(steer["_meta"]?["steering"]?["idleBehavior"]?.stringValue == "promptRequired")
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true)
        #expect(try await said(core, id) == ["first", "and also this"], "said where it went in")

        gate.open()
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        // Longer than a drain would take: nothing going out is the assertion.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await agent.received.filter { $0 == ACP.Method.prompt }.count == 1, "one turn, not two")
        #expect(try await said(core, id) == ["first", "and also this"], "and not said a second time")
    }

    @Test func promptRequiredSendsTheWordsAsTheNextTurn() async throws {
        let gate = TurnGate()
        let (core, launcher, id, queued) = try await queuedBehindATurn(steering: "promptRequired", gate: gate)
        let first = try #require(launcher.lastAgent)

        try await core.sendNow(.init(agentID: id, promptID: queued.id))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["and also this"],
                "handed back, and waiting for the turn the daemon still thinks is running")
        #expect(await first.steers.count == 1)

        gate.open()
        // A runtime is handed back between turns, so the second turn is a second process.
        await eventually("they went as a prompt of their own") {
            await launcher.lastAgent?.promptContent?.arrayValue?.first?["text"]?.stringValue == "and also this"
        }
        await eventually("and that turn ended") {
            let agent = await core.agent(id)
            return agent?.queuedPrompts.isEmpty == true && agent?.state == .finished
        }
        #expect(try await said(core, id) == ["first", "and also this"], "said once")
    }

    @Test func aFailedSteerKeepsTheWordsAndSaysSo() async throws {
        let gate = TurnGate()
        let (core, _, id, queued) = try await queuedBehindATurn(steering: "failed", gate: gate)

        try await core.sendNow(.init(agentID: id, promptID: queued.id))

        #expect(await core.agent(id)?.queuedPrompts.map(\.id) == [queued.id])
        #expect(try await notes(core, id).contains { $0.contains("still waiting") })
        #expect(try await said(core, id) == ["first"])
        gate.open()
    }

    @Test func aRuntimeThatNeverAdvertisedItIsRefused() async throws {
        let gate = TurnGate()
        let (core, launcher, id, queued) = try await queuedBehindATurn(steering: nil, gate: gate)

        await #expect(throws: JSONRPCError.self) {
            try await core.sendNow(.init(agentID: id, promptID: queued.id))
        }
        #expect(await core.agent(id)?.queuedPrompts.map(\.id) == [queued.id], "the words are where they were")
        #expect(await launcher.lastAgent?.received.contains(ACP.Method.steering) == false)
        gate.open()
    }

    /// The Claude adapter delivers a steer `later` while a permission is waiting on the
    /// person, rather than cancel the request. So the card must still be there after.
    @Test func aWaitingPermissionCardIsLeftAlone() async throws {
        let gate = TurnGate()
        let permission: JSONValue = [
            "toolCall": ["toolCallId": "t1", "title": "Write hello.txt"],
            "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]],
        ]
        let (core, _, id, queued) = try await queuedBehindATurn(steering: "injected", gate: gate,
                                                                 permission: permission)

        try await core.sendNow(.init(agentID: id, promptID: queued.id))

        let pending = await core.pendingPermissionRequests()
        #expect(pending.count == 1, "the card is still waiting")
        #expect(await core.agent(id)?.state == .waitingOnUser)
        try await core.answerPermission(.init(permissionID: try #require(pending.first).id, optionID: "allow"))
        gate.open()
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
    }

    /// With no turn of ours running there is nothing to steer into, and "now" is simply
    /// the front of the queue.
    @Test func withNoTurnRunningItGoesAsAnOrdinaryPrompt() async throws {
        let gate = TurnGate()
        let (core, launcher, id, queued) = try await queuedBehindATurn(steering: "injected", gate: gate)
        try await core.stop(id)
        gate.open()
        await eventually("stopped, words kept") {
            let agent = await core.agent(id)
            return agent?.state.hasTurnInFlight == false && agent?.queuedPrompts.count == 1
        }

        try await core.sendNow(.init(agentID: id, promptID: queued.id))

        await eventually("it went as a turn") { await core.agent(id)?.queuedPrompts.isEmpty == true }
        #expect(await launcher.lastAgent?.steers.isEmpty == true, "no steer with nothing to steer into")
        #expect(try await said(core, id) == ["first", "and also this"])
    }
}
