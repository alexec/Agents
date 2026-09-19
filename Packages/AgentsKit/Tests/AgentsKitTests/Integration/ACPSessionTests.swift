import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

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

    /// What the session had to say while `work` ran.
    ///
    /// `until` is what to wait for, and it is the caller's own assertion said twice on
    /// purpose. Events cross from the transport's reader into the stream on a task of
    /// their own, so they land an unknowable moment after the call that caused them
    /// returned; ending the stream on a timer ends it before the last of them arrives
    /// often enough to matter. Pass nothing for a test that asserts an absence, where
    /// there is no event to wait for and time passing is the whole assertion.
    private func collect(_ session: ACPSession,
                         until: (@Sendable ([ACPSessionEvent]) -> Bool)? = nil,
                         while work: () async throws -> Void) async rethrows -> [ACPSessionEvent] {
        let stream = session.eventStream()
        let seen = Seen()
        let collector = Task { for await event in stream { seen.append(event) } }
        try await work()
        if let until {
            await eventually("the session said everything it was going to") { until(seen.all) }
        } else {
            try? await Task.sleep(for: .milliseconds(120))
        }
        await session.noteExit(status: 0) // ends the stream
        _ = await collector.value
        return seen.all
    }

    /// A usage update sent last as a marker, for the tests that emit one for the
    /// purpose. Nothing sent before it can still be in the air once it is here.
    private var hasUsage: @Sendable ([ACPSessionEvent]) -> Bool {
        { $0.contains { if case .usageChanged = $0 { return true } else { return false } } }
    }

    /// What has arrived so far, readable while the collector is still filling it.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ACPSessionEvent] = []
        func append(_ event: ACPSessionEvent) { lock.lock(); events.append(event); lock.unlock() }
        var all: [ACPSessionEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    @Test func runsAWholeTurn() async throws {
        var script = FakeACPAgent.Script()
        script.updates = [FakeACPAgent.chunk("Pine", messageID: "m1"),
                          FakeACPAgent.chunk("apple", messageID: "m1")]
        script.title = "Pineapple"
        let (session, agent) = pair(script)

        var result: TurnResult?
        let events = try await collect(session, until: { events in
            let texts = events.compactMap { if case .entry(let kind) = $0, case .agentMessage(_, let t, _) = kind { return t } else { return nil } }
            return texts == ["Pine", "apple"]
                && events.contains { if case .titleChanged("Pineapple") = $0 { return true } else { return false } }
        }) {
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
        //
        // The replay is suppressed while the load is in flight, and the hard part is
        // where that window ends. The chunks arrive as notifications, handled on the
        // reader's own task; the load's answer resumes this one. Closing the window on
        // the answer leaves the last chunk still queued behind it, and that chunk gets
        // recorded — which is how a resumed conversation ended up with the end of its
        // history written in twice.
        //
        // Left to the scheduler that happens perhaps one run in five, which is no way
        // to know whether it is fixed. So this arranges it: the runtime asks us to read
        // a big file on its way into the replay, and we serve that read on the session
        // actor, synchronously. Everything arriving while we are busy with it queues up
        // behind it — the first chunk, then the load's own answer, then the second
        // chunk, in that order. Unfixed, the second chunk is recorded every single time.
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var script = FakeACPAgent.Script()
        script.supportsResume = false
        script.replayOnLoad = [FakeACPAgent.chunk("old line one"), FakeACPAgent.chunk("old line two")]
        script.requestDuringLoad = (ACP.ClientMethod.readTextFile,
                                    ["path": .string(try slowToRead(in: folder).path),
                                     "line": 1, "limit": 1])
        script.pauseBeforeReplay = .milliseconds(20)
        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine,
                                 capabilities: ACP.ClientCapabilities(readTextFile: true))
        let agent = FakeACPAgent(script: script, transport: theirs)
        await session.serve(scope: FolderScope(folders: [folder]), terminals: nil)

        // An absence, so there is nothing to wait for: the replay either reaches the
        // stream in that time or it never does. The wait can only let a leak through
        // as a pass, never invent one.
        let events = try await collect(session) {
            try await session.initialize()
            try await session.continueSession(id: "s", cwd: URL(fileURLWithPath: "/tmp"))
        }
        let entries = events.filter { if case .entry = $0 { return true } else { return false } }
        #expect(entries.isEmpty, "the replay must not reach the transcript")
        #expect(await agent.received.contains(ACP.Method.loadSession))
    }

    @Test func aLoadDoesNotReturnUntilItsReplayHasBeenDealtWith() async throws {
        // The other side of the same guarantee, and the reason it can be a guarantee
        // rather than a hope. Adopting a conversation we never had is the one case
        // where the replay is the transcript, so here every line must be kept — and
        // kept before `continueSession` returns, because that is what the caller then
        // goes on to write down.
        //
        // No wait anywhere in this one: the assertion is the ordering itself. The
        // stream is ended the instant the load returns, so a chunk still queued
        // somewhere is a chunk that never arrives.
        let folder = try scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var script = FakeACPAgent.Script()
        script.supportsResume = false
        script.replayOnLoad = [FakeACPAgent.chunk("old line one"), FakeACPAgent.chunk("old line two")]
        script.requestDuringLoad = (ACP.ClientMethod.readTextFile,
                                    ["path": .string(try slowToRead(in: folder).path),
                                     "line": 1, "limit": 1])
        script.pauseBeforeReplay = .milliseconds(20)
        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine,
                                 capabilities: ACP.ClientCapabilities(readTextFile: true))
        let agent = FakeACPAgent(script: script, transport: theirs)
        await session.serve(scope: FolderScope(folders: [folder]), terminals: nil)

        let stream = session.eventStream()
        let seen = Seen()
        let collector = Task { for await event in stream { seen.append(event) } }
        try await session.initialize()
        await session.setReplayRecorded(true)
        try await session.continueSession(id: "s", cwd: URL(fileURLWithPath: "/tmp"))
        await session.noteExit(status: 0)
        _ = await collector.value

        let texts = seen.all.compactMap {
            if case .entry(let kind) = $0, case .agentMessage(_, let text, _) = kind { return text } else { return nil }
        }
        #expect(texts == ["old line one", "old line two"],
                "the load must not return with any of its replay still in the air")
        #expect(await agent.received.contains(ACP.Method.loadSession))
    }

    /// A folder of our own to put a file in, removed by the test that made it.
    private func scratchFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A file that takes a good fraction of a second to serve a read of, so that what
    /// arrives while we are busy with it is a certainty rather than a guess.
    ///
    /// Five megabytes over two hundred thousand lines, and both numbers earn their
    /// place: the size is what the read costs and the line count is what splitting
    /// them costs. A smaller file was tried and is not enough — under the load of the
    /// whole suite it stops holding the session for long enough, and the test goes
    /// back to passing on unfixed code about half the time. This margin is an order of
    /// magnitude more than everything it has to outlast.
    private func slowToRead(in folder: URL) throws -> URL {
        let url = folder.appending(path: "history.txt")
        try String(repeating: "the quick brown fox jumps\n", count: 200_000)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
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
        // The usage update goes last and is what to wait for: the stream is in order,
        // so once it is here so is everything sent before it.
        let events = try await collect(session, until: hasUsage) {
            try await session.initialize()
            try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))
            await agent.emit(["sessionUpdate": "something_new_next_year", "payload": 1])
            await agent.emit(["sessionUpdate": "usage_update", "used": 10, "size": 100])
        }
        let unknown = events.compactMap { if case .unknownUpdate(let k) = $0 { return k } else { return nil } }
        #expect(unknown == ["something_new_next_year"], "ignored-on-purpose and unrecognised are different things")
    }

    @Test func aNotificationUnderAMethodWeDoNotKnowIsReportedRatherThanDropped() async throws {
        // Cursor sends three of these, under `cursor/`. Before this they returned at the
        // guard in `receive` and left nothing behind at all, so an agent could be quietly
        // poorer for what it was sent and nobody could tell.
        let (session, agent) = pair()
        let events = try await collect(session, until: hasUsage) {
            try await session.initialize()
            try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))
            await agent.emitNotification("cursor/update_todos", ["todos": ["one", "two"]])
            await agent.emitNotification("something/inventedNextYear")
            await agent.emit(["sessionUpdate": "usage_update", "used": 10, "size": 100])
        }
        let unknown = events.compactMap {
            if case .unknownNotification(let m) = $0 { return m } else { return nil }
        }
        #expect(unknown == ["cursor/update_todos", "something/inventedNextYear"])
        // The known traffic either side of it is untouched.
        #expect(events.contains { if case .usageChanged = $0 { return true } else { return false } })
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
