import Foundation
import Testing
@testable import AgentsKit

@Suite("ACP session", .timeLimit(.minutes(1)))
struct ACPSessionTests {
    /// A session wired to a fake agent, with no process, no network and no credentials.
    ///
    /// Hold on to the agent for as long as the test runs. Letting it go deallocates the
    /// other end of the connection, and a session whose runtime has silently vanished
    /// waits for ever rather than failing.
    private func pair(_ script: FakeACPAgent.Script = .init()) -> (ACPSession, FakeACPAgent) {
        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine)
        let agent = FakeACPAgent(script: script, transport: theirs)
        return (session, agent)
    }

    private func collect(_ session: ACPSession, while work: () async throws -> Void) async rethrows -> [ACPSessionEvent] {
        let stream = session.eventStream()
        let collector = Task { () -> [ACPSessionEvent] in
            var events: [ACPSessionEvent] = []
            for await event in stream { events.append(event) }
            return events
        }
        try await work()
        try? await Task.sleep(for: .milliseconds(120))
        await session.noteExit(status: 0) // ends the stream
        return await collector.value
    }

    @Test func runsAWholeTurn() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [FakeACPAgent.chunk("Pine", messageID: "m1"),
                          FakeACPAgent.chunk("apple", messageID: "m1")]
        script.title = "Pineapple"
        let (session, agent) = pair(script)

        var result: TurnResult?
        let events = try await collect(session) {
            try await session.initialize()
            try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))
            result = try await session.prompt("Say pineapple")
        }

        #expect(result?.reason == .endTurn)
        let texts = events.compactMap { if case .entry(let kind) = $0, case .agentMessage(_, let t, _) = kind { return t } else { return nil } }
        #expect(texts == ["Pine", "apple"])
        #expect(events.contains { if case .titleChanged("Pineapple") = $0 { return true } else { return false } })
        #expect(await agent.received.contains(ACP.Method.initialize))
    }

    @Test func advertisedOptionsAreTakenWholeAndAppliedBySettingThem() async throws {
        var script = FakeACPAgent.Script()
        script.configOptions = [
            ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                         currentValue: "a", options: [ConfigChoice(value: "a", name: "A"),
                                                      ConfigChoice(value: "b", name: "B")]),
            ConfigOption(id: "mystery", name: "Mystery", category: "unheard_of", type: "slider"),
        ]
        let (session, agent) = pair(script)
        try await session.initialize()
        try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))

        let options = await session.options
        #expect(options.count == 2)
        #expect(options[0].isRenderable)
        #expect(!options[1].isRenderable, "an option type we do not know is skipped, not guessed at")

        await session.apply(StartOptions(values: ["model": "b"]))
        let applied = await agent.setOptions
        #expect(applied.count == 1)
        #expect(applied.first?.id == "model")
        #expect(applied.first?.value.stringValue == "b")
    }

    @Test func aPermissionBlocksTheAgentUntilItIsAnswered() async throws {
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["toolCallId": "t1", "title": "Write hello.txt"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                         ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]
        let (session, agent) = pair(script)
        try await session.initialize()
        try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))

        let stream = session.eventStream()
        let asked = Task { () -> PermissionRequest? in
            for await event in stream {
                if case .permissionRequested(let request) = event { return request }
            }
            return nil
        }
        let turn = Task { try await session.prompt("write a file") }

        guard let request = await asked.value else { Issue.record("no permission asked"); return }
        #expect(request.toolCall.title == "Write hello.txt")
        #expect(request.options.count == 2)
        #expect(request.options.first?.kind.allows == true)

        // The turn is still in flight: nothing has answered.
        #expect(!turn.isCancelled)
        await session.answerPermission(id: request.id, optionID: "allow")

        let result = try await turn.value
        #expect(result.reason == .endTurn)
        let outcome = await agent.permissionOutcome
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "selected")
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "allow")
    }

    @Test func aCancelledPermissionIsAnsweredRatherThanLeftHanging() async throws {
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Something"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]]
        let (session, agent) = pair(script)
        try await session.initialize()
        try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))

        let stream = session.eventStream()
        let asked = Task { () -> PermissionRequest? in
            for await event in stream {
                if case .permissionRequested(let request) = event { return request }
            }
            return nil
        }
        let turn = Task { try await session.prompt("do it") }
        guard let request = await asked.value else { Issue.record("no permission asked"); return }
        await session.answerPermission(id: request.id, optionID: nil)
        _ = try await turn.value

        let outcome = await agent.permissionOutcome
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "cancelled")
    }

    @Test func resumeIsUsedWhereItIsAdvertisedAndLoadWhereItIsNot() async throws {
        var resuming = FakeACPAgent.Script()
        resuming.supportsResume = true
        let (a, resumeAgent) = pair(resuming)
        try await a.initialize()
        try await a.continueSession(id: "s1", cwd: URL(fileURLWithPath: "/tmp"))
        #expect(await resumeAgent.received.contains(ACP.Method.resumeSession))
        #expect(!(await resumeAgent.received.contains(ACP.Method.loadSession)))

        var loading = FakeACPAgent.Script()
        loading.supportsResume = false
        let (b, loadAgent) = pair(loading)
        try await b.initialize()
        try await b.continueSession(id: "s2", cwd: URL(fileURLWithPath: "/tmp"))
        #expect(await loadAgent.received.contains(ACP.Method.loadSession))
        #expect(!(await loadAgent.received.contains(ACP.Method.resumeSession)))
    }

    @Test func aLoadReplayIsNotRecordedTwice() async throws {
        // We keep our own transcript, so a replayed conversation is confirmation
        // rather than content. Recording it would double every line.
        var script = FakeACPAgent.Script()
        script.supportsResume = false
        script.replayOnLoad = [FakeACPAgent.chunk("old line one"), FakeACPAgent.chunk("old line two")]
        let (session, agent) = pair(script)

        let events = try await collect(session) {
            try await session.initialize()
            try await session.continueSession(id: "s", cwd: URL(fileURLWithPath: "/tmp"))
        }
        let entries = events.filter { if case .entry = $0 { return true } else { return false } }
        #expect(entries.isEmpty, "the replay must not reach the transcript")
        #expect(await agent.received.contains(ACP.Method.loadSession))
    }

    @Test func aRuntimeThatHasLostTheSessionSaysSo() async throws {
        var script = FakeACPAgent.Script()
        script.supportsResume = true
        script.sessionGoneError = JSONRPCError(code: -32602, message: "no such session")
        let (session, agent) = pair(script)
        try await session.initialize()

        await #expect(throws: ACPSessionError.self) {
            try await session.continueSession(id: "gone", cwd: URL(fileURLWithPath: "/tmp"))
        }
        #expect(await agent.received.contains(ACP.Method.resumeSession))
    }

    @Test func anUnknownUpdateIsReportedAndSkipped() async throws {
        let (session, agent) = pair()
        let events = try await collect(session) {
            try await session.initialize()
            try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))
            await agent.emit(["sessionUpdate": "something_new_next_year", "payload": 1])
            await agent.emit(["sessionUpdate": "usage_update", "used": 10, "size": 100])
        }
        let unknown = events.compactMap { if case .unknownUpdate(let k) = $0 { return k } else { return nil } }
        #expect(unknown == ["something_new_next_year"], "ignored-on-purpose and unrecognised are different things")
    }

    @Test func anUnknownIncomingMethodIsDeclinedLoudly() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine)
        let runtime = JSONRPCConnection(transport: theirs)
        await runtime.start()
        try await session.initializeIgnoringResult()

        await #expect(throws: JSONRPCError.self) {
            try await runtime.call("fs/read_text_file", ["path": "/etc/passwd"])
        }
        await runtime.close()
    }

    @Test func aRuntimeThatDiesMidTurnEndsThePermissionAndTheStream() async throws {
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Something"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]]
        let (session, agent) = pair(script)
        try await session.initialize()
        try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))

        let stream = session.eventStream()
        let asked = Task { () -> Bool in
            for await event in stream {
                if case .permissionRequested = event { return true }
            }
            return false
        }
        let turn = Task { try? await session.prompt("do it") }
        #expect(await asked.value)

        await session.noteExit(status: 9)
        #expect(await session.outstandingPermissionIDs.isEmpty,
                "a dead runtime leaves nothing waiting on an answer that can no longer matter")
        turn.cancel()
        withExtendedLifetime(agent) {}
    }
}

extension ACPSession {
    /// The handshake, for a test that only wants the connection running.
    func initializeIgnoringResult() async throws {
        _ = try? await initialize()
    }
}
