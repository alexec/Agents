import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Daemon", .timeLimit(.minutes(1)))
struct DaemonTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDaemonTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Wait until this agent reads the way the caller says it should.
    ///
    /// Every wait in this file names the thing the assertion after it names. There is
    /// no general "the daemon has stopped moving" to wait for: `finishTurn` takes the
    /// turn task off the books before it records usage, moves the state or lets the
    /// runtime go, so anything watching for quiet is told the turn is over several
    /// awaits before the values a test reads are written.
    private func waitFor(_ core: DaemonCore, _ id: UUID,
                         _ description: @autoclosure @Sendable () -> String,
                         sourceLocation: SourceLocation = #_sourceLocation,
                         _ matches: @Sendable @escaping (Agent) -> Bool) async {
        await eventually(description(), sourceLocation: sourceLocation) {
            guard let agent = await core.agent(id) else { return false }
            return matches(agent)
        }
    }

    /// Finished, and its runtime handed back.
    ///
    /// Both, for the tests that prompt again afterwards: `finishTurn` moves the state
    /// before it calls `releaseRuntime`, so a prompt sent on the state alone can land
    /// on the session that is still open and no second runtime is ever started.
    private func letGo(_ core: DaemonCore, _ id: UUID) async throws {
        await waitFor(core, id, "the turn ended") { $0.state == .finished }
        await eventually("its runtime was handed back") { await core.live[id] == nil }
    }

    // MARK: Starting and watching

    @Test func startsAnAgentAndRecordsWhatItSays() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [FakeACPAgent.chunk("Working"), FakeACPAgent.chunk(" on it")]
        script.title = "Say hello"
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "say hello"))
        // The title too, not just the state. It comes down the session's event stream
        // and lands after the turn has ended, so an agent read on the state alone is
        // still wearing the placeholder made from the prompt.
        await waitFor(core, id, "the turn ended and the runtime had named it") {
            $0.state == .finished && $0.endedReason == .endTurn && $0.title == "Say hello"
        }

        let agent = await core.agent(id)
        #expect(agent?.state == .finished)
        #expect(agent?.endedReason == .endTurn)
        #expect(agent?.title == "Say hello", "the runtime's own title names the agent")
        #expect(agent?.runtimeSessionID != nil)

        // Chunks come down the same stream, so the last of them can still be in the
        // air when the turn is over.
        @Sendable func texts() async -> [String] {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.compactMap(\.text) ?? []
        }
        await eventually("every chunk reached the transcript") {
            let said = await texts()
            return said.contains("say hello") && said.contains("Working") && said.contains(" on it")
        }

        let texts = await texts()
        #expect(texts.contains("say hello"))
        #expect(texts.contains("Working"))
        #expect(texts.contains(" on it"))
    }

    @Test func aFinishedAgentsProcessIsLetGo() async throws {
        // Every runtime hands its session back after the process is gone, so holding
        // one open for an idle agent buys nothing and works against the exit rule.
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "hello"))
        await eventually("the daemon is holding nothing") { await core.isHoldingAgents == false }

        #expect(await core.isHoldingAgents == false)
        #expect(await core.shouldExit, "nothing running and nobody watching")
    }

    @Test func theOptionsFormComesFromOneSessionThatTheStartThenUses() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.configOptions = [ConfigOption(id: "model", name: "Model", category: "model",
                                             type: "select", currentValue: "a",
                                             options: [ConfigChoice(value: "a", name: "A"),
                                                       ConfigChoice(value: "b", name: "B")])]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let offered = try await core.options(.init(runtimeID: "copilot", cwd: work))
        #expect(offered.options.count == 1)
        #expect(launcher.launchCount == 1)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go",
                                            startOptions: StartOptions(values: ["model": "b"]),
                                            draftID: offered.draftID))
        await waitFor(core, id, "the turn ended") { $0.state == .finished }
        #expect(launcher.launchCount == 1, "the draft session is used rather than a second runtime started")
        #expect(await core.agent(id)?.state == .finished)

        let applied = await launcher.lastAgent?.setOptions
        #expect(applied?.first?.id == "model")
        #expect(applied?.first?.value.stringValue == "b")
    }

    @Test func aRuntimeThatIsNotThereIsAnErrorTheAppCanShow() async throws {
        let (locations, work) = try temporary()
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: RuntimeDiscovery(searchPaths: ["/nowhere"], fileExists: { _ in false }),
                              launcher: FakeLauncher())
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        }
    }

    // MARK: Surviving

    @Test func anAgentFoundDeadOnStartUpIsSaidToBeStopped() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s1")
        try await store.save(wasRunning)

        let core = try core(FakeLauncher(), locations: locations)
        let recovered = await core.recover()

        #expect(recovered == [wasRunning.id])
        let agent = await core.agent(wasRunning.id)
        #expect(agent?.state == .stopped)
        #expect(agent?.endedReason == .daemonGone)

        let page = try await core.transcript(.init(agentID: wasRunning.id))
        #expect(page.entries.contains { ($0.text ?? "").contains("daemon stopped") })
    }

    @Test func anAgentFoundDeadOnStartUpIsPickedBackUpAndToldWhy() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s1")
        try await store.save(wasRunning)

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await waitFor(core, wasRunning.id, "it was picked back up and worked again") {
            $0.state == .finished
        }
        #expect(launcher.launchCount == 1, "one runtime, started again for it")
        #expect(await launcher.lastAgent?.continuedSessionParams != nil,
                "the same conversation, continued rather than begun afresh")

        let page = try await core.transcript(.init(agentID: wasRunning.id))
        #expect(page.entries.contains { ($0.text ?? "").contains("The app restarted while you were working") },
                "and it is told why it is being spoken to")
    }

    @Test func anAgentWaitingOnAnAnswerIsToldItsQuestionWentWithTheDaemon() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let wasAsking = Agent(runtimeID: "grok", cwd: work, state: .waitingOnUser, runtimeSessionID: "s1")
        try await store.save(wasAsking)

        let core = try core(FakeLauncher(), locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await waitFor(core, wasAsking.id, "it was picked back up") { $0.state == .finished }
        let page = try await core.transcript(.init(agentID: wasAsking.id))
        #expect(page.entries.contains { ($0.text ?? "").contains("the question you had asked went with it") })
    }

    @Test func anAgentWhoseRuntimeHasGoneIsLeftAloneWithAnExplanation() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s1")
        try await store.save(wasRunning)

        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: RuntimeDiscovery(searchPaths: ["/nowhere"], fileExists: { _ in false }),
                              launcher: FakeLauncher())
        await core.pickUpAfterRestart(await core.recover())

        await eventually("it said why it could not") {
            let page = try? await core.transcript(.init(agentID: wasRunning.id))
            return page?.entries.contains { ($0.text ?? "").contains("Could not pick this agent back up") } ?? false
        }
        #expect(await core.agent(wasRunning.id)?.state == .stopped)
        #expect(await core.agent(wasRunning.id)?.queuedPrompts.isEmpty == true,
                "and the words about the restart are not left waiting to be sent next week")
    }

    @Test func theRecordIsWrittenAsThingsHappenNotAtTheEnd() async throws {
        // A daemon killed mid-turn still has to leave something true behind.
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = (0..<20).map { FakeACPAgent.chunk("chunk \($0)") }
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        // The file, not the daemon's memory — and the file is what has to be waited
        // for, since it is the only thing this test reads.
        @Sendable func linesOnDisk() -> [Substring] {
            guard let text = try? String(contentsOf: locations.transcript(id), encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n")
        }
        await eventually("everything reached the file") { linesOnDisk().count >= 22 }

        let lines = linesOnDisk()
        #expect(lines.count >= 22, "the prompt, twenty chunks and the state changes are all on disk")
    }

    // MARK: Talking to an agent

    @Test func aPermissionIsHeldWithNobodyConnectedAndAnsweredLater() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Write hello.txt"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                         ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        // The request is held before the state moves, so the later of the two is the
        // one to wait on.
        await waitFor(core, id, "the agent is waiting on its question") { $0.state == .waitingOnUser }

        let agent = await core.agent(id)
        #expect(agent?.state == .waitingOnUser)
        let waiting = await core.pendingPermissionRequests()
        #expect(waiting.count == 1)
        #expect(waiting.first?.toolCall.title == "Write hello.txt")

        // Nobody is connected, and the daemon must not go anywhere.
        await core.setConnectionCount(0)
        #expect(await core.isHoldingAgents, "an agent waiting on an answer is work in hand")
        #expect(await core.shouldExit == false)

        try await core.answerPermission(.init(permissionID: waiting[0].id, optionID: "allow"))
        await waitFor(core, id, "the turn ran on to its end") { $0.state == .finished }
        await eventually("the question was taken down") {
            await core.pendingPermissionRequests().isEmpty
        }

        #expect(await core.agent(id)?.state == .finished)
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "allow")
        #expect(await core.pendingPermissionRequests().isEmpty)
    }

    @Test func stoppingAnAgentThatIsWaitingAnswersTheQuestionRatherThanLeavingItHanging() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Something"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await waitFor(core, id, "the agent is waiting on its question") { $0.state == .waitingOnUser }
        #expect(await core.agent(id)?.state == .waitingOnUser)

        try await core.stop(id)
        await waitFor(core, id, "the agent stopped, cancelled") {
            $0.state == .stopped && $0.endedReason == .cancelled
        }
        let outcome = await eventuallySome("the question was answered for the agent") {
            await launcher.lastAgent?.permissionOutcome
        }

        #expect(await core.agent(id)?.state == .stopped)
        #expect(await core.agent(id)?.endedReason == .cancelled)
        #expect(await core.pendingPermissionRequests().isEmpty)
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "cancelled")
    }

    @Test func aPromptToARunningAgentIsRefusedRatherThanQueuedSilently() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Wait here"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]]
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await waitFor(core, id, "the agent is waiting on its question") { $0.state == .waitingOnUser }

        // Waiting on a permission is not running, so a follow-up is allowed to be
        // refused for a different reason: what must not happen is silence.
        let state = await core.agent(id)?.state
        #expect(state == .waitingOnUser)
    }

    // MARK: Picking an agent back up

    @Test func aStoppedAgentIsPickedUpRatherThanCopied() async throws {
        let (locations, work) = try temporary()
        var resuming = FakeACPAgent.Script()
        resuming.supportsResume = true
        let launcher = FakeLauncher(script: resuming)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "first"))
        try await letGo(core, id)
        let sessionID = await core.agent(id)?.runtimeSessionID
        #expect(await core.agent(id)?.state == .finished)

        try await core.prompt(.init(agentID: id, text: "second"))
        // The second launch is what the assertion is about, so it is what to wait for.
        await eventually("the runtime was started again") { launcher.launchCount == 2 }
        await waitFor(core, id, "the second turn ended") { $0.state == .finished }

        #expect(await core.allAgents().count == 1, "the same agent, not a copy")
        #expect(await core.agent(id)?.runtimeSessionID == sessionID, "the same runtime session")
        #expect(launcher.launchCount == 2, "the runtime was started again")
        let resumed = await launcher.lastAgent?.received ?? []
        #expect(resumed.contains(ACP.Method.resumeSession))
        #expect(!resumed.contains(ACP.Method.newSession))
    }

    @Test func anAgentWhoseRuntimeHasLostTheSessionCarriesOnAsTheSameAgent() async throws {
        let (locations, work) = try temporary()
        var first = FakeACPAgent.Script()
        first.supportsResume = true
        var gone = FakeACPAgent.Script()
        gone.supportsResume = true
        gone.sessionGoneError = JSONRPCError(code: -32602, message: "no such session")
        let launcher = FakeLauncher(script: first, then: [first, gone])
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "first"))
        try await letGo(core, id)
        let originalSession = await core.agent(id)?.runtimeSessionID

        try await core.prompt(.init(agentID: id, text: "second"))
        await waitFor(core, id, "the agent is on a new runtime session") {
            $0.runtimeSessionID != originalSession
        }
        await eventually("the loss was written down") {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.contains { ($0.text ?? "").contains("no longer has this conversation") } == true
        }

        let agent = await core.agent(id)
        #expect(await core.allAgents().count == 1, "still one agent")
        #expect(agent?.runtimeSessionID != originalSession, "a new runtime session against the same agent")
        let page = try await core.transcript(.init(agentID: id))
        #expect(page.entries.contains { ($0.text ?? "").contains("no longer has this conversation") })
        #expect(page.entries.contains { ($0.text ?? "") == "first" }, "the history is kept")
    }

    @Test func anArchivedAgentComesBackWhenItIsPromptedAgain() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.supportsResume = true
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "one"))
        try await letGo(core, id)
        try await core.archive(id)
        #expect(await core.agent(id)?.state == .archived)

        try await core.prompt(.init(agentID: id, text: "two"))
        await waitFor(core, id, "it came back and finished, unarchived") {
            $0.state == .finished && $0.archivedReason == nil
        }
        #expect(await core.agent(id)?.state == .finished)
        #expect(await core.agent(id)?.archivedReason == nil)
    }

    // MARK: Getting finished work out of the way

    @Test func nothingArchivesItself() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await waitFor(core, id, "the turn ended and nothing archived it") {
            $0.state == .finished && $0.archivedReason == nil
        }
        #expect(await core.agent(id)?.state == .finished, "finished, and still on the list")
        #expect(await core.agent(id)?.archivedReason == nil)
    }

    @Test func aTurnThatStopsShortIsNotAFinish() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.stopReason = "refusal"
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await waitFor(core, id, "the turn stopped short, refused") {
            $0.state == .stopped && $0.endedReason == .refusal
        }
        #expect(await core.agent(id)?.state == .stopped)
        #expect(await core.agent(id)?.endedReason == .refusal)
    }

    @Test func aStopReasonWeHaveNeverHeardOfIsRecordedRatherThanRounded() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.stopReason = "ran_out_of_biscuits"
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await waitFor(core, id, "the turn ended with a reason we do not know") {
            $0.endedReason == .unrecognised
        }
        await eventually("the reason was written down as given") {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.contains { ($0.text ?? "").contains("ran_out_of_biscuits") } == true
        }

        #expect(await core.agent(id)?.endedReason == .unrecognised)
        let page = try await core.transcript(.init(agentID: id))
        #expect(page.entries.contains { ($0.text ?? "").contains("ran_out_of_biscuits") })
    }

    @Test func archivingALiveAgentStopsItFirst() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Hold on"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]]
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await waitFor(core, id, "the agent is waiting on its question") { $0.state == .waitingOnUser }
        #expect(await core.agent(id)?.state == .waitingOnUser)

        try await core.archive(id)
        await waitFor(core, id, "the agent archived") { $0.state == .archived }
        await eventually("nothing is left running behind it") { await core.isHoldingAgents == false }
        #expect(await core.agent(id)?.state == .archived)
        #expect(await core.isHoldingAgents == false, "nothing is left running behind an archived agent")
    }
}

@Suite("Slash commands, end to end", .timeLimit(.minutes(1)))
struct DaemonSlashCommandTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSlashTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private var commandsUpdate: JSONValue {
        ["sessionUpdate": "available_commands_update",
         "availableCommands": [["name": "review", "description": "Run code review"],
                               ["name": "add-dir", "description": "Allow a directory",
                                "input": ["hint": "directory"]]]]
    }

    @Test func aNewChatKnowsWhatTheRuntimeTakes() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [commandsUpdate]
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)

        // The commands arrive with the first turn in the fake, as they do in a real
        // runtime: after the session exists rather than with it.
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await eventually("both commands arrived") {
            await core.agent(id)?.availableCommands.map(\.name) == ["review", "add-dir"]
        }

        let agent = await core.agent(id)
        #expect(agent?.availableCommands.map(\.name) == ["review", "add-dir"])
        #expect(agent?.availableCommands.last?.inputHint == "directory")
    }

    @Test func aPickedUpAgentKeepsTheCommandsItsNewRuntimeDoesNotRepeat() async throws {
        let (locations, work) = try temporary()
        var advertises = FakeACPAgent.Script()
        advertises.updates = [commandsUpdate]
        // The first runtime says what it takes; the second says nothing, which is what a
        // real one does when a session is loaded rather than made — the list was sent
        // once, into the session this one is picking up. FakeLauncher hands out `then`
        // first and falls back to `script`, so this is that order.
        let launcher = FakeLauncher(script: FakeACPAgent.Script(), then: [advertises])
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the commands arrived") {
            await core.agent(id)?.availableCommands.map(\.name) == ["review", "add-dir"]
        }
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        await eventually("its runtime was handed back") { await core.live[id] == nil }

        try await core.prompt(.init(agentID: id, text: "again"))
        await eventually("the second turn ended") { await core.agent(id)?.state == .finished }
        #expect(launcher.launchCount == 2, "a second runtime was started for it")
        #expect(await core.agent(id)?.availableCommands.map(\.name) == ["review", "add-dir"],
                "what it takes is still on the record, rather than wiped by a runtime that said nothing")
    }

    @Test func theyAreKeptOnTheRecordForAnAgentWithNoProcessLeft() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [commandsUpdate]
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        #expect(await core.agent(id)?.state == .finished, "its runtime has been let go")

        // Read back by a store of its own, so it is the file that has to be waited on.
        // `changed` saves on a detached task, which means the record in memory is right
        // some way before the record on disk is.
        let reread = await eventuallySome("the commands reached the file") {
            let onDisk = try? await AgentStore(locations: locations).load(id)
            return onDisk?.availableCommands.map(\.name) == ["review", "add-dir"] ? onDisk : nil
        }
        #expect(reread?.availableCommands.map(\.name) == ["review", "add-dir"])
    }
}
