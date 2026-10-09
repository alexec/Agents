import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `finish_turn` ends the turn on every runtime, not only on the ones that let go of the
/// prompt by themselves (#139).
///
/// Each fake here keeps its `session/prompt` open after the call, as Copilot, Codex and
/// OpenCode did in the #47 assessment: a gate nobody opens. Some hear `session/cancel`,
/// as the real adapters do, and one does not.
@Suite("finish_turn ends the turn", .timeLimit(.minutes(1)))
struct FinishTurnEndsTurnTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsTurnEnds-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work.resolvingSymlinksInPath()))
    }

    private func makeCore(_ locations: StoreLocations, _ launcher: FakeLauncher,
                          grace: FinishGrace, quiet: QuietGate? = nil) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        var quietWait: (@Sendable () async -> Void)?
        if let quiet { quietWait = { await quiet.wait() } }
        await core.setFinishGrace(grace, quietWait: quietWait)
        return core
    }

    /// A turn that never ends by itself.
    private static func keepsGoing(_ gate: TurnGate, hearsCancel: Bool) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.gate = gate
        script.endsOnCancel = hearsCancel
        return script
    }

    private func start(_ core: DaemonCore, in folder: URL, _ title: String) async throws -> (UUID, String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: title))
        let token = UUID().uuidString
        await core.bindAppToken(token, to: id)
        return (id, token)
    }

    @discardableResult
    private func finish(_ core: DaemonCore, _ id: UUID, _ token: String, _ outcome: String, _ message: String,
                        waitingOn: [String]? = nil) async throws -> String {
        await core.bindAppToken(token, to: id)
        return try await core.finishTurn(.init(token: token, outcome: outcome, message: message,
                                               prompts: [], waitingOn: waitingOn))
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
            if case .runtimeNote(let text) = $0.kind { return text }
            return nil
        }
    }

    private func said(_ core: DaemonCore, _ id: UUID) async throws -> String {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
            if case .agentMessage(_, let text, _) = $0.kind { return text }
            return nil
        }.joined()
    }

    private func running(_ core: DaemonCore, _ id: UUID) async {
        await eventually("the turn is under way") { await core.agent(id)?.state == .running }
    }

    /// The case from the issue: the agent has said it is done, the runtime is still in its
    /// turn. The app cancels it, and the `cancelled` that comes back reads as the
    /// ordinary ending: finished, with the agent's own account, its runtime let go, and
    /// no question about how it went.
    @Test func aRuntimeStillInItsTurnIsCancelledAndEndsAsTheAgentSaid() async throws {
        let (locations, work) = try temporary()
        let gate = TurnGate()
        let launcher = FakeLauncher(script: Self.keepsGoing(gate, hearsCancel: true))
        let core = try await makeCore(locations, launcher,
                                      grace: FinishGrace(quiet: .milliseconds(200), afterCancel: .seconds(20)))
        let (id, token) = try await start(core, in: work, "Fix the login")
        await running(core, id)
        await eventually("the fake is in its turn") { gate.turnsArrived == 1 }

        try await finish(core, id, token, "done", "Fixed the redirect.")
        await settled(core, id, "the turn ended after finish_turn")

        let agent = try #require(await core.agent(id))
        #expect(agent.state == .finished)
        #expect(agent.endedReason == .endTurn, "cancelled by the app reads as the agent's own ending")
        #expect(agent.report?.outcome == .done)
        #expect(agent.report?.message == "Fixed the redirect.")
        #expect(!agent.outcomeAsked, "it said how it went, so it is not asked")
        #expect(await launcher.lastAgent?.cancels == 1)
        #expect(await core.live[id] == nil, "the runtime was let go")
        #expect(await core.finishedTurns[id] == nil)
        #expect(try await notes(core, id).contains { $0.contains("still going after the agent ended its turn") })
        gate.open()
    }

    /// Codex in its own `wait` (#139): a runtime that does not answer the cancel either.
    /// The app ends the turn without it, and the prompt's late answer ends nothing again.
    @Test func aRuntimeThatIgnoresTheCancelIsEndedAnyway() async throws {
        let (locations, work) = try temporary()
        let gate = TurnGate()
        let launcher = FakeLauncher(script: Self.keepsGoing(gate, hearsCancel: false))
        let core = try await makeCore(locations, launcher,
                                      grace: FinishGrace(quiet: .milliseconds(200), afterCancel: .milliseconds(300)))
        let (id, token) = try await start(core, in: work, "Port the model")
        await running(core, id)
        await eventually("the fake is in its turn") { gate.turnsArrived == 1 }

        try await finish(core, id, token, "partly_done", "Ported half; the rest needs a call.")
        await settled(core, id, "the turn ended without the runtime's answer")

        let agent = try #require(await core.agent(id))
        #expect(agent.state == .finished)
        #expect(agent.endedReason == .endTurn)
        #expect(agent.report?.outcome == .partlyDone)
        // The app's cancel, and the one letting its session go, which it ignores too.
        #expect((await launcher.lastAgent?.cancels ?? 0) >= 1)
        #expect(await core.turnTasks[id] == nil)
        // Its late answer, if it ever comes, is let go: the record keeps one ending.
        gate.open()
        try await Task.sleep(for: .milliseconds(300))
        let endings = try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.filter {
            if case .stateChanged(.finished, _) = $0.kind { return true }
            return false
        }
        #expect(endings.count == 1)
    }

    /// With the warm pool on (#183): a runtime that answered the cancel is idle, and may be
    /// kept for the reply; one that did not is still inside its turn, and never is.
    ///
    /// The one that answers is given a minute to do it, so a busy machine cannot make its
    /// answer late; the wait is cut short only for the one that never answers (#225).
    @Test func aWarmPoolKeepsOnlyARuntimeThatAnsweredTheCancel() async throws {
        let (locations, work) = try temporary()
        let answered = TurnGate(), ignored = TurnGate()
        let launcher = FakeLauncher(script: Self.keepsGoing(answered, hearsCancel: true),
                                    then: [Self.keepsGoing(answered, hearsCancel: true),
                                           Self.keepsGoing(ignored, hearsCancel: false)],
                                    keepsRuntimesWarm: true)
        let core = try await makeCore(locations, launcher,
                                      grace: FinishGrace(quiet: .milliseconds(200), afterCancel: .seconds(60)))
        let (heard, heardToken) = try await start(core, in: work, "Fix the login")
        await running(core, heard)
        // In its turn before the cancel comes: a cancel before then is one it cannot hear.
        await eventually("the fake is in its turn") { answered.turnsArrived == 1 }
        try await finish(core, heard, heardToken, "done", "Fixed.")
        await settled(core, heard, "the turn ended on the cancel")
        await eventually("the pool kept it") { await core.decidedForTest(heard) }
        #expect(await core.warm[heard] != nil, "idle after its cancel, so kept for the reply")

        await core.setFinishGrace(FinishGrace(quiet: .milliseconds(200), afterCancel: .milliseconds(300)))
        let (deaf, deafToken) = try await start(core, in: work, "Port the model")
        await running(core, deaf)
        await eventually("the fake is in its turn") { ignored.turnsArrived == 1 }
        try await finish(core, deaf, deafToken, "done", "Ported.")
        await settled(core, deaf, "the turn ended without the runtime's answer")
        await eventually("the runtime was let go") { await core.live[deaf] == nil }
        #expect(await core.warm[deaf] == nil, "still in its turn, so never kept")
        answered.open()
        ignored.open()
    }

    /// The point of the issue: an agent waiting on a helper is resumed when the helper
    /// says it is done, not when the helper's runtime gets round to letting go.
    @Test func anAgentWaitingOnAHelperIsResumedWhenTheHelperFinishes() async throws {
        let (locations, work) = try temporary()
        let helperGate = TurnGate()
        let launcher = FakeLauncher(script: .init(), then: [Self.keepsGoing(helperGate, hearsCancel: true)])
        let core = try await makeCore(locations, launcher,
                                      grace: FinishGrace(quiet: .milliseconds(200), afterCancel: .seconds(20)))
        let (helper, helperToken) = try await start(core, in: work, "Helper")
        let (lead, leadToken) = try await start(core, in: work, "Lead")
        await settled(core, lead)
        try await finish(core, lead, leadToken, "blocked", "Waiting on the helper.", waitingOn: [helper.uuidString])
        await running(core, helper)

        try await finish(core, helper, helperToken, "done", "Done.")
        await eventually("the lead was resumed") {
            let entries = (try? await core.transcript(.init(agentID: lead, before: nil, limit: 500)).entries) ?? []
            return entries.contains {
                if case .userMessage(let text, _, .app) = $0.kind { return text.hasPrefix("The block you reported has cleared") }
                return false
            }
        }
        #expect(await core.agent(helper)?.endedReason == .endTurn)
        helperGate.open()
    }

    /// A closing message after the call is not cut off: words keep the turn open, and
    /// what was said is on the record when the app ends it.
    @Test func wordsAfterTheCallAreGivenTheirTime() async throws {
        let (locations, work) = try temporary()
        let gate = TurnGate()
        let quiet = QuietGate()
        let launcher = FakeLauncher(script: Self.keepsGoing(gate, hearsCancel: true))
        let core = try await makeCore(locations, launcher,
                                      grace: FinishGrace(afterCancel: .seconds(20)), quiet: quiet)
        let (id, token) = try await start(core, in: work, "Write the notes")
        await running(core, id)
        await eventually("the fake is in its turn") { gate.turnsArrived == 1 }
        let fake = try #require(launcher.lastAgent)

        try await finish(core, id, token, "done", "Notes written.")
        await eventually("the app waits for quiet") { quiet.waiting == 1 }
        // A closing message in four pieces, all heard while the app waits for quiet, so
        // the quiet it waited for is not quiet any more.
        for piece in ["All ", "done: ", "notes ", "written."] {
            await fake.emit(["sessionUpdate": "agent_message_chunk",
                             "content": ["type": "text", "text": .string(piece)]])
        }
        await eventually("the words are heard") {
            (try? await said(core, id).contains("All done: notes written.")) == true
        }
        quiet.pass()
        await eventually("the app waits for quiet again") { quiet.arrivals == 2 }
        #expect(await fake.cancels == 0, "still talking, so not cancelled")
        quiet.pass()
        await settled(core, id, "ended once it went quiet")
        #expect(await fake.cancels == 1)
        #expect(try await said(core, id).contains("All done: notes written."))
        #expect(await core.agent(id)?.endedReason == .endTurn)
        gate.open()
    }

    /// A runtime that lets go by itself, as Claude's does, is never cancelled.
    @Test func aRuntimeThatEndsByItselfIsNotCancelled() async throws {
        let (locations, work) = try temporary()
        let gate = TurnGate()
        let launcher = FakeLauncher(script: Self.keepsGoing(gate, hearsCancel: true))
        // A quiet far longer than the turn takes to end once let go, however loaded the
        // machine: half a second raced the gate opening (#225).
        let core = try await makeCore(locations, launcher,
                                      grace: FinishGrace(quiet: .seconds(30), afterCancel: .seconds(20)))
        let (id, token) = try await start(core, in: work, "Quick one")
        await running(core, id)
        await eventually("the fake is in its turn") { gate.turnsArrived == 1 }
        try await finish(core, id, token, "done", "Done.")
        gate.open()
        await settled(core, id)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await launcher.lastAgent?.cancels == 0)
        #expect(try await notes(core, id).allSatisfy { !$0.contains("still going") })
        #expect(await core.agent(id)?.endedReason == .endTurn)
    }
}

/// The quiet after `finish_turn`, passed when the test says so (#225): the app waits
/// here instead of on the clock, one wait at a time.
final class QuietGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var count = 0

    /// How many waits for quiet have begun.
    var arrivals: Int { lock.withLock { count } }
    /// How many are waiting now.
    var waiting: Int { lock.withLock { held.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                count += 1
                held.append(continuation)
            }
        }
    }

    /// The quiet has passed, for the wait in progress.
    func pass() {
        let next = lock.withLock { held.isEmpty ? nil : held.removeFirst() }
        next?.resume()
    }
}
