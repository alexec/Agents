import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Runtimes that hang, in each place one can (#166): the handshake, a new conversation, a
/// pick-up's load, and a turn that goes silent. Each is ended with its reason, and the
/// others carry on meanwhile.
@Suite("Runtime deadlines", .timeLimit(.minutes(1)))
struct RuntimeDeadlineTests {
    /// Short enough for a test, long enough that a fake that does answer always does.
    static let short = RuntimeDeadlines(handshake: .milliseconds(300), start: .milliseconds(300),
                                        load: .milliseconds(300), silence: .milliseconds(400))

    // MARK: Starting

    @Test func aHandshakeThatNeverComesIsEndedWithItsReason() async throws {
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .seconds(30)
        let (core, _, work) = try make(FakeLauncher(script: script, deadlines: Self.short))
        let error = await #expect(throws: JSONRPCError.self) {
            try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        }
        #expect(error?.code == DaemonAPI.Failure.runtimeWillNotStart)
        #expect(error?.message == "Grok did not answer its handshake in a moment, so the app ended it.")
        #expect(await core.live.isEmpty)
    }

    @Test func aConversationThatNeverStartsIsEndedWithItsReason() async throws {
        var script = FakeACPAgent.Script()
        script.newSessionDelay = .seconds(30)
        let (core, _, work) = try make(FakeLauncher(script: script, deadlines: Self.short))
        let error = await #expect(throws: JSONRPCError.self) {
            try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        }
        #expect(error?.message.contains("did not start a conversation") == true)
        #expect(await core.live.isEmpty)
    }

    /// A load that hangs is not "the runtime no longer has it": the conversation is not
    /// thrown away for a new one just because the runtime was slow.
    @Test func aPickUpWhoseLoadHangsIsEndedWithItsReason() async throws {
        var script = FakeACPAgent.Script()
        script.loadDelay = .seconds(30)
        let launcher = FakeLauncher(script: script, deadlines: Self.short)
        let (core, store, work) = try make(launcher)
        let hung = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s")
        try await store.save(hung)
        await core.pickUpAfterRestart(await core.recover())

        await eventually("it was let go with its reason") {
            await self.notes(core, hung.id).contains { $0.contains("Grok did not pick its conversation back up in a moment, so the app ended it.") }
        }
        await eventually("and left the queue") { await core.stillResuming().isEmpty }
        #expect(await core.agent(hung.id)?.state == .stopped)
        #expect(await core.agent(hung.id)?.runtimeSessionID == "s", "its conversation is kept")
        #expect(await !self.notes(core, hung.id).contains { $0.contains("no longer has this conversation") })
        #expect(await core.live[hung.id] == nil)
        let received = await launcher.lastAgent?.received ?? []
        #expect(!received.contains(ACP.Method.newSession))
    }

    // MARK: A silent turn

    @Test func aTurnThatGoesSilentIsEndedWithItsReason() async throws {
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(30)
        let (core, store, work) = try make(FakeLauncher(script: script, deadlines: Self.short))
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))

        await eventually("it was ended") { await core.agent(id)?.state == .stopped }
        let notes = await notes(core, id)
        #expect(notes.contains("Grok said nothing for a moment with nothing pending, so the app ended it. Send it a message to pick it back up."))
        #expect(!notes.contains { $0.contains("stopped answering") }, "said once, not twice")
        await eventually("the runtime is let go") { await core.live[id] == nil }
        await eventually("and its transcript") { await !store.holdsTranscript(of: id) }
        await eventually("and the watch stops with no turn to watch") { await core.silenceWatch == nil }
    }

    /// A build, a test run, the app's own `wait_for_event`: quiet, and working.
    @Test func aToolCallStillOpenIsNotSilence() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Build",
                           "kind": "execute", "status": "in_progress"]]
        script.delayAfterUpdates = .milliseconds(1500)
        let (core, _, work) = try make(FakeLauncher(script: script, deadlines: Self.short))
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))

        await eventually("the turn ended by itself") { await core.agent(id)?.state.hasTurnInFlight == false }
        #expect(await core.agent(id)?.endedReason == .endTurn)
        #expect(await !self.notes(core, id).contains { $0.contains("said nothing") })
    }

    // MARK: One hung pick-up and the rest

    /// The most recent chat hangs on its load and holds its lane; the other two come back
    /// through the other one meanwhile. Then it is let go at its deadline.
    @Test func aHungPickUpDoesNotHoldUpTheOthers() async throws {
        var hangs = FakeACPAgent.Script()
        hangs.loadDelay = .seconds(30)
        var works = FakeACPAgent.Script()
        works.turnDelay = .milliseconds(100)
        let deadlines = RuntimeDeadlines(handshake: .seconds(30), start: .seconds(30),
                                         load: .seconds(3), silence: .seconds(30))
        let launcher = FakeLauncher(script: works, then: [hangs], deadlines: deadlines)
        let (core, store, work) = try make(launcher)
        let now = Date()
        let hung = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "h", lastActivityAt: now)
        let second = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "a",
                           lastActivityAt: now.addingTimeInterval(-60))
        let third = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "b",
                          lastActivityAt: now.addingTimeInterval(-120))
        for agent in [hung, second, third] { try await store.save(agent) }
        await core.pickUpAfterRestart(await core.recover())

        await eventually("the other two came back") {
            let a = await core.agent(second.id)?.state, b = await core.agent(third.id)?.state
            return a == .finished && b == .finished
        }
        #expect(await core.stillResuming() == [hung.id], "while the hung one still holds its lane")
        await eventually("then it was let go with its reason") {
            await self.notes(core, hung.id).contains { $0.contains("did not pick its conversation back up in 3 seconds") }
        }
        await eventually("and the queue is empty") { await core.stillResuming().isEmpty }
    }

    // MARK: The session on its own

    /// A real process that never answers: given up at the deadline, and ended with nothing
    /// left of it (#163).
    @Test func aRealRuntimeThatNeverAnswersIsEndedWhole() async throws {
        let session = try ACPSession.launch(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "sleep 60"],
                                            cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
                                            environment: [:],
                                            launch: RuntimeLaunch(runtimeID: "fake", deadlines: Self.short))
        let process = try #require(await session.runtimeProcess)
        await #expect(throws: RuntimeDidNotAnswer(phase: .handshake, after: .milliseconds(300))) {
            try await session.initialize()
        }
        await session.end(gracePeriod: .milliseconds(200))
        #expect(!process.isRunning)
        #expect(!process.watchesStandardError)
    }

    @Test func aLateAnswerAfterTheDeadlineIsDropped() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let connection = JSONRPCConnection(transport: mine)
        let far = JSONRPCConnection(transport: theirs) { _, _ in
            try? await Task.sleep(for: .milliseconds(300))
            return .success("late")
        }
        await far.start()
        await connection.start()
        await #expect(throws: JSONRPCTimeout.self) {
            try await connection.call("slow", nil, timeout: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(400))
        // The connection is still good for the next call.
        #expect(try await connection.call("slow", nil, timeout: .seconds(5)) == "late")
    }

    // MARK: Helpers

    private func make(_ launcher: FakeLauncher) throws -> (DaemonCore, AgentStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDeadlines-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let store = try AgentStore(locations: locations)
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: launcher)
        return (core, store, Project.standardize(work))
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async -> [String] {
        let entries = (try? await core.transcript(.init(agentID: id)).entries) ?? []
        return entries.compactMap { if case .runtimeNote(let text) = $0.kind { text } else { nil } }
    }

    private func eventually(_ what: String, _ check: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if await check() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("never happened: \(what)")
    }
}
