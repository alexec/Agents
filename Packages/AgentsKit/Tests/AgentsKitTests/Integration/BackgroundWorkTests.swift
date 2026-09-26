import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Background shells and subagents (057), as Claude's adapter 0.81.2 sends them once the
/// client opts in to JetBrains "AIR". Every shape here is from a real turn, captured in
/// `specs/057-background-tasks/probe/claude-0.81.2-wire.jsonl`, trimmed.
@Suite("Background work", .timeLimit(.minutes(1)))
struct BackgroundWorkTests {
    // MARK: The captured shapes

    static let shellSpawned: JSONValue = [
        "sessionUpdate": "async_task_spawned", "asyncTaskId": "bixt00wz6",
        "name": "Print a tick every second for 5 minutes", "taskType": "shell",
        "description": "Print a tick every second for 5 minutes",
        "showInTranscript": false, "canStop": true]
    /// The Bash call that starts it, which is the only place the command line is.
    static let shellCall: JSONValue = [
        "sessionUpdate": "tool_call_update", "toolCallId": "toolu_01JBKqYEYTNwBecLVD7vX3q2",
        "kind": "execute", "title": "for i in $(seq 1 300); do echo tick $i; sleep 1; done",
        "rawInput": ["command": "for i in $(seq 1 300); do echo tick $i; sleep 1; done",
                     "description": "Print a tick every second for 5 minutes",
                     "run_in_background": true]]
    static let shellLinked: JSONValue = [
        "sessionUpdate": "async_task_progress", "asyncTaskId": "bixt00wz6",
        "toolCallId": "toolu_01JBKqYEYTNwBecLVD7vX3q2"]
    static let shellOutput: JSONValue = [
        "sessionUpdate": "async_task_progress", "asyncTaskId": "bixt00wz6",
        "outputFilePath": "/private/tmp/claude-501/x/tasks/bixt00wz6.output",
        "toolCallId": "toolu_01JBKqYEYTNwBecLVD7vX3q2"]
    static let subagentSpawned: JSONValue = [
        "sessionUpdate": "subagent_spawned", "subagentSessionId": "a9fc7de39cd11c2dd",
        "name": "Count files",
        "task": "Run `ls /usr/bin | wc -l` with Bash, then run `sleep 20` with Bash, then report the count.",
        "capabilities": [:]]
    static let subagentDone: JSONValue = [
        "sessionUpdate": "subagent_state_update", "subagentSessionId": "a9fc7de39cd11c2dd",
        "state": "completed"]
    static let subagent = "a9fc7de39cd11c2dd"

    // MARK: Reading them

    @Test func theFiveKindsAreRead() throws {
        guard case .spawned(let shell) = try #require(BackgroundUpdate.decode(Self.shellSpawned)) else {
            Issue.record("a shell was not read as spawned"); return
        }
        #expect(shell.id == "bixt00wz6")
        #expect(shell.kind == .task && shell.isShell)
        #expect(shell.name == "Print a tick every second for 5 minutes")
        #expect(shell.canStop && shell.isRunning)

        guard case .spawned(let sub) = try #require(BackgroundUpdate.decode(Self.subagentSpawned)) else {
            Issue.record("a subagent was not read as spawned"); return
        }
        #expect(sub.kind == .subagent && sub.name == "Count files")
        // No runtime offers to stop a subagent on its own: `capabilities: {}`.
        #expect(!sub.canStop && !sub.offersStop)
        #expect(sub.detail?.hasPrefix("Run `ls") == true)

        #expect(BackgroundUpdate.decode(Self.shellOutput) == .progress(
            id: "bixt00wz6", detail: nil, summary: nil, lastToolName: nil,
            outputFilePath: "/private/tmp/claude-501/x/tasks/bixt00wz6.output",
            toolCallID: "toolu_01JBKqYEYTNwBecLVD7vX3q2"))
        #expect(BackgroundUpdate.decode(Self.subagentDone) == .state(
            id: Self.subagent, .completed, summary: nil, outputFilePath: nil))
        // Codex and Claude say "cancelled" for a subagent stopped with the agent.
        #expect(BackgroundUpdate.decode(["sessionUpdate": "subagent_state_update",
                                         "subagentSessionId": "s", "state": "cancelled"])
                == .state(id: "s", .stopped, summary: nil, outputFilePath: nil))

        // Through the one decoder every update goes through, and not "unknown".
        guard case .background = SessionUpdate.decode(Self.shellSpawned) else {
            Issue.record("async_task_spawned fell through"); return
        }
        guard case .unknown = SessionUpdate.decode(["sessionUpdate": "async_task_spawned"]) else {
            Issue.record("one with no id was taken"); return
        }
    }

    @Test func aRepeatedEndingSaysNothingTheSecondTime() throws {
        let start = Date(timeIntervalSince1970: 0)
        var items: [BackgroundItem] = []
        var announced: [BackgroundItem] = []
        for update in [Self.shellSpawned, Self.shellLinked, Self.shellOutput,
                       // Stop, as captured: the ending twice.
                       ["sessionUpdate": "async_task_state_update", "asyncTaskId": "bixt00wz6", "state": "stopped"],
                       ["sessionUpdate": "async_task_state_update", "asyncTaskId": "bixt00wz6", "state": "stopped"]] as [JSONValue] {
            let decoded = try #require(BackgroundUpdate.decode(update, now: start))
            let result = BackgroundItem.applying(decoded, to: items, now: start.addingTimeInterval(37))
            items = result.items
            if let item = result.announce { announced.append(item) }
        }
        #expect(announced.map(\.state) == [.running, .stopped])
        #expect(items.count == 1)
        #expect(items[0].toolCallID == "toolu_01JBKqYEYTNwBecLVD7vX3q2")
        #expect(items[0].outputFilePath?.hasSuffix("bixt00wz6.output") == true)
        #expect(BackgroundWords.age(items[0]) == "0:37")
    }

    @Test func anUpdateForSomethingNeverAnnouncedChangesNothing() {
        let result = BackgroundItem.applying(.state(id: "ghost", .completed, summary: nil, outputFilePath: nil), to: [])
        #expect(result.items.isEmpty && result.announce == nil)
    }

    @Test func onlyTheNewestFinishedOnesAreKept() {
        var items: [BackgroundItem] = [BackgroundItem(id: "live", kind: .task, name: "live", taskType: "shell")]
        for i in 0..<(BackgroundItem.finishedKept + 5) {
            items = BackgroundItem.applying(.spawned(BackgroundItem(id: "\(i)", kind: .task, name: "\(i)")), to: items).items
            items = BackgroundItem.applying(.state(id: "\(i)", .completed, summary: nil, outputFilePath: nil), to: items).items
        }
        #expect(items.filter { !$0.isRunning }.count == BackgroundItem.finishedKept)
        #expect(items.contains { $0.id == "live" })
        #expect(!items.contains { $0.id == "0" })
    }

    @Test func theMarkCountsWhatRuns() {
        let items = [BackgroundItem(id: "a", kind: .task, name: "a", taskType: "shell"),
                     BackgroundItem(id: "b", kind: .subagent, name: "b"),
                     BackgroundItem(id: "c", kind: .task, name: "c", taskType: "shell", state: .completed)]
        #expect(BackgroundWords.mark(items) == "1 shell, 1 subagent in the background")
        #expect(BackgroundWords.mark([items[2]]) == nil)
    }

    // MARK: Advertising

    @Test func theAppOptsInAndNothingElseDoes() {
        let air = ACP.ClientCapabilities.app.wire["_meta"]?["jetbrains"]?["air"]
        #expect(air?["version"]?.intValue == 1)
        // 052's typed session failures ride in the same list.
        #expect(air?["capabilities"] == ["asyncTasks", "nativeSubagentSessions", "sessionFailure"])
        #expect(ACP.ClientCapabilities.none.wire["_meta"] == nil)
        // Every runtime the daemon starts gets the same offer, Gemini's policy included:
        // what arrives is decided by what the runtime does with it, not by its name.
        for runtime in RuntimeCatalog.builtIn {
            let caps = ProcessSessionLauncher.capabilities(for: ToolPolicyCatalog.policy(for: runtime.id))
            #expect(caps.backgroundTasks && caps.subagentSessions, "\(runtime.id)")
        }
    }

    // MARK: Through the daemon

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsBackgroundTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    /// The captured turn: a shell, a subagent that runs a command, asks, speaks and
    /// finishes, and the agent's own reply.
    private var capturedTurn: FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.air = [
            (nil, Self.shellCall), (nil, Self.shellSpawned), (nil, Self.shellLinked), (nil, Self.shellOutput),
            (nil, Self.subagentSpawned),
            (Self.subagent, ["sessionUpdate": "tool_call", "toolCallId": "toolu_sub1", "title": "ls /usr/bin | wc -l",
                             "kind": "execute", "status": "pending"]),
            (Self.subagent, ["sessionUpdate": "tool_call_update", "toolCallId": "toolu_sub1", "status": "completed"]),
            (Self.subagent, FakeACPAgent.chunk("`/usr/bin` holds 932 entries.")),
            // Not the agent's meter.
            (Self.subagent, ["sessionUpdate": "usage_update", "used": 999_999, "size": 1_000_000]),
            (nil, Self.subagentDone),
        ]
        script.withoutAir = [FakeACPAgent.chunk("Command running in background with ID: bixt00wz6.")]
        script.updates = [FakeACPAgent.chunk("Both are running.")]
        return script
    }

    /// The captured turn, held open until the test lets it end: the runtime is let go
    /// when a turn ends, and Stop needs one that is still there.
    private func held() -> (FakeACPAgent.Script, TurnGate) {
        var script = capturedTurn
        let gate = TurnGate()
        script.gate = gate
        return (script, gate)
    }

    private func entries(_ core: DaemonCore, _ id: UUID) async throws -> [TranscriptEntry] {
        try await core.transcript(.init(agentID: id)).entries
    }

    @Test func aShellAndASubagentAreListedAndTheSubagentKeepsItsOwnWords() async throws {
        let (locations, work) = try temporary()
        let (script, gate) = held()
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn is at work") { gate.turnsArrived == 1 }
        // Sent before the gate, and read by the client in its own time.
        await eventually("both are on the record, the subagent done") {
            let items = await core.agent(id)?.background ?? []
            return items.contains { $0.id == "bixt00wz6" }
                && items.contains { $0.id == Self.subagent && $0.state == .completed }
        }
        await eventually("the subagent's report is written") {
            ((try? await entries(core, id)) ?? []).contains { $0.subagentID == Self.subagent && $0.text != nil }
        }

        let agent = try #require(await core.agent(id))
        let shell = try #require(agent.background.first { $0.id == "bixt00wz6" })
        #expect(shell.isRunning && shell.offersStop)
        #expect(shell.toolCallID == "toolu_01JBKqYEYTNwBecLVD7vX3q2")
        #expect(shell.command == "for i in $(seq 1 300); do echo tick $i; sleep 1; done",
                "found on the call that started it, for the row's hover")
        #expect(shell.name == "Print a tick every second for 5 minutes", "the row still leads with the name")
        let sub = try #require(agent.background.first { $0.id == Self.subagent })
        #expect(sub.state == .completed && sub.endedAt != nil)
        // The subagent's context is not the agent's.
        #expect(agent.usage?.used != 999_999)

        let record = try await entries(core, id)
        let chat = TranscriptEntry.display(record)
        let chatText = chat.compactMap { item -> String? in
            if case .entry(let entry) = item { return entry.text }; return nil
        }.joined(separator: "\n")
        #expect(chatText.contains("Both are running."))
        #expect(!chatText.contains("932"), "the subagent's report was read as the agent's")
        #expect(!chatText.contains("Command running in background"), "the prose came although the app opted in")

        let steps = TranscriptEntry.display(record, subagent: Self.subagent)
        #expect(steps.contains { $0.latestToolCall?.toolCallID == "toolu_sub1" })
        #expect(steps.contains { if case .entry(let e) = $0 { return e.text?.contains("932") == true }; return false })
        #expect(!steps.contains { if case .entry(let e) = $0 { return e.text == "Both are running." }; return false })

        // A line when each started, and one when the subagent finished.
        let lines = record.compactMap { entry -> BackgroundItem? in
            if case .background(let item) = entry.kind { return item }; return nil
        }
        #expect(lines.map(\.id) == ["bixt00wz6", Self.subagent, Self.subagent])
        #expect(lines.last?.state == .completed)
        gate.open()
    }

    @Test func stopReachesTheRuntimeAndTheRowEndsOnce() async throws {
        let (locations, work) = try temporary()
        let (script, gate) = held()
        defer { gate.open() }
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn is at work") { gate.turnsArrived == 1 }

        await eventually("the shell is listed") {
            await core.agent(id)?.background.contains { $0.id == "bixt00wz6" } == true
        }
        // A running subagent cannot be stopped on its own, and the runtime is not asked.
        let fakeAgent = try #require(launcher.lastAgent)
        await fakeAgent.emit(["sessionUpdate": "subagent_spawned", "subagentSessionId": "s2",
                              "name": "Second", "task": "t", "capabilities": [:]])
        await eventually("the second subagent is listed") {
            await core.agent(id)?.background.contains { $0.id == "s2" } == true
        }
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.stopBackground(.init(agentID: id, itemID: "s2"))
        }
        // One that has finished is simply not stopped.
        #expect(try await core.stopBackground(.init(agentID: id, itemID: Self.subagent)) == false)
        #expect(try await core.stopBackground(.init(agentID: id, itemID: "bixt00wz6")))
        await eventually("the shell has stopped") {
            await core.agent(id)?.background.first { $0.id == "bixt00wz6" }?.state == .stopped
        }
        let fake = try #require(launcher.lastAgent)
        let asked = await fake.stopRequests
        #expect(asked.count == 1)
        #expect(asked.first?["asyncTaskId"]?.stringValue == "bixt00wz6")
        #expect(asked.first?["sessionId"]?.stringValue == (await core.agent(id)?.runtimeSessionID))

        // Once for one click: the runtime's notice, and no line of ours beside it.
        await eventually("the notice is written") {
            ((try? await entries(core, id)) ?? []).contains {
                if case .notice(let n) = $0.kind { return n.title == "Task stopped by user" }; return false
            }
        }
        let endings = try await entries(core, id).filter {
            if case .background(let item) = $0.kind { return item.id == "bixt00wz6" && !item.isRunning }; return false
        }
        #expect(endings.isEmpty)
        #expect(await core.agent(id)?.background.first { $0.id == "bixt00wz6" }?.isStopping == false)

        // A second Stop finds it gone and says so without failing.
        #expect(try await core.stopBackground(.init(agentID: id, itemID: "bixt00wz6")) == false)
    }

    @Test func aSubagentsQuestionIsNamedAsItsOwn() async throws {
        let (locations, work) = try temporary()
        var script = capturedTurn
        script.permission = ["sessionId": .string(Self.subagent),
                             "toolCall": ["toolCallId": "toolu_sub2", "title": "sleep 20", "kind": "execute"],
                             "options": [["optionId": "allow-once", "name": "Yes", "kind": "allow_once"]]]
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the question is up") { await core.agent(id)?.state == .waitingOnUser }
        let asked = try #require(await core.pendingPermissionRequests().first)
        #expect(asked.subagent == "Count files")
    }

    @Test func whenTheRuntimeGoesWhatItRanIsOver() async throws {
        let (locations, work) = try temporary()
        let (script, gate) = held()
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn is at work") { gate.turnsArrived == 1 }
        await eventually("the shell is running") {
            await core.agent(id)?.background.contains { $0.isRunning } == true
        }

        // The turn ends, and the runtime is let go with it.
        gate.open()
        await eventually("the turn ends") { await core.agent(id)?.state == .finished }
        let shell = try #require(await core.agent(id)?.background.first { $0.id == "bixt00wz6" })
        #expect(shell.state == .disconnected && !shell.offersStop)
    }

    @Test func aClientThatDidNotOptInIsSentNoneOfIt() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: capturedTurn, capabilities: .none)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ends") { await core.agent(id)?.state == .finished }
        #expect(await core.agent(id)?.background.isEmpty == true)
        // And Stop is not asked of a runtime that was never told the app can.
        await eventually("the prose is written") {
            ((try? await entries(core, id)) ?? []).compactMap(\.text).joined().contains("Command running in background")
        }
    }
}
