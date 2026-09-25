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

    /// Opus 5.5, told to say nothing, streams zero-width spaces — once, twenty-two
    /// thousand of them, one chunk each. None of it is anything to read.
    @Test func zeroWidthChunksAreNotRecorded() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = Array(repeating: FakeACPAgent.chunk("\u{200B}\u{200B}"), count: 40)
            + [FakeACPAgent.chunk("Done"), FakeACPAgent.chunk("\n\n"), FakeACPAgent.chunk("\u{200B}")]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "report"))
        @Sendable func said() async -> [String] {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.compactMap { entry in
                guard case .agentMessage(_, let text, _) = entry.kind else { return nil }
                return text
            } ?? []
        }
        await eventually("the reply reached the transcript") { await said().contains("\n\n") }

        // The words and the paragraph break are kept; not one zero-width chunk is.
        #expect(await said() == ["Done", "\n\n"])
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
        // Read here, before the turn has ended: the claim is about the start, and a
        // turn that ends without saying how it went is asked, which starts one of its
        // own a moment later.
        #expect(launcher.launchCount == 1, "the draft session is used rather than a second runtime started")
        await waitFor(core, id, "the turn ended") { $0.state == .finished }
        #expect(await core.agent(id)?.state == .finished)

        // The first runtime's, not the last one's: the turn's ending is asked about,
        // and that question starts a runtime of its own with no options set on it.
        let applied = await launcher.allAgents.first?.setOptions
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
        #expect(await core.agent(wasRunning.id)?.queuedPrompts.contains { $0.text.contains("The app restarted") } != true,
                "found and removed by what they say, not by where in the queue they were put")
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

    // MARK: Coming back after a restart

    /// Three at once, all of them, not just whichever the dictionary happened to
    /// hand over first.
    @Test func severalInterruptedAgentsAreAllPickedBackUp() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        var saved: [Agent] = []
        for _ in 0..<3 {
            let agent = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s")
            try await store.save(agent)
            saved.append(agent)
        }

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        for agent in saved {
            await waitFor(core, agent.id, "it came back") { $0.state == .finished }
        }
        // One runtime each to bring them back. Each of those turns then ends without
        // saying how it went and is asked once, which is a runtime each again — so the
        // number that matters is that no agent was started twice to be picked up.
        #expect(launcher.launchCount <= 6, "one runtime each to pick up, and one to ask")
        #expect(launcher.launchCount >= 3)
    }

    /// The chat the person was last watching should not wait behind every runtime
    /// ahead of it, and `agents` is a dictionary with no order to trust.
    @Test func theyComeBackMostRecentlyActiveFirst() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let now = Date()
        // Saved oldest first, so any test that passes by accident of insertion order
        // would report the wrong order here.
        let oldest = Agent(runtimeID: "grok", cwd: work, title: "oldest", state: .running,
                           runtimeSessionID: "s", lastActivityAt: now.addingTimeInterval(-300))
        let middle = Agent(runtimeID: "copilot", cwd: work, title: "middle", state: .running,
                           runtimeSessionID: "s", lastActivityAt: now.addingTimeInterval(-60))
        let newest = Agent(runtimeID: "cursor", cwd: work, title: "newest", state: .running,
                           runtimeSessionID: "s", lastActivityAt: now)
        for agent in [oldest, middle, newest] { try await store.save(agent) }

        // A turn long enough that none of the three ends while the others are still
        // being picked up. A turn that ends without saying how it went is asked, and
        // that question starts a runtime of its own, which would land in this order.
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(2)
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await eventually("all three were started") { launcher.launchCount == 3 }
        #expect(launcher.launches.map(\.runtime) == ["cursor", "copilot", "grok"],
                "most recently active first")
    }

    /// Nothing is running yet, and an idle daemon must not exit out from under them.
    @Test func agentsComingBackHoldTheDaemonOpen() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .milliseconds(400)
        try await store.save(Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s"))

        let core = try core(FakeLauncher(script: script), locations: locations)
        await core.setConnectionCount(0)
        await core.pickUpAfterRestart(await core.recover())

        #expect(await core.isHoldingAgents, "a pick-up in hand is work in hand")
        #expect(await core.shouldExit == false, "so no window is needed to keep it alive")
    }

    /// The whole batch is said to be coming back before any of it begins, and each
    /// one is said to have left the queue as it goes.
    @Test func anAgentOnItsWayBackUpIsBroadcastAsResuming() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let first = Agent(runtimeID: "grok", cwd: work, state: .running,
                          runtimeSessionID: "s", lastActivityAt: Date())
        let second = Agent(runtimeID: "grok", cwd: work, state: .running,
                           runtimeSessionID: "s", lastActivityAt: Date().addingTimeInterval(-60))
        for agent in [first, second] { try await store.save(agent) }

        let heard = Broadcasts()
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .milliseconds(200)
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        await core.setBroadcaster { method, params in
            Task { await heard.record(method, params) }
        }
        await core.pickUpAfterRestart(await core.recover())

        await eventually("both were said to be coming back") {
            await heard.resuming(true).count == 2
        }
        #expect(launcher.launchCount <= 1,
                "and said so before the second runtime was anywhere near being started")

        await eventually("and each was said to have left the queue") {
            await heard.resuming(false).count == 2
        }
        #expect(await heard.resuming(true) == [first.id, second.id])
    }

    /// A window that connects part-way through the batch asks rather than guesses.
    @Test func aWindowConnectingLateIsToldWhatIsStillComingBack() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .milliseconds(300)
        var saved: [Agent] = []
        for index in 0..<3 {
            let agent = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s",
                              lastActivityAt: Date().addingTimeInterval(Double(-index)))
            try await store.save(agent)
            saved.append(agent)
        }

        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        // Mid-batch: the first is on its way and the other two are still waiting.
        await eventually("the first is being started") { launcher.launchCount == 1 }
        let midway = await core.stillResuming()
        #expect(midway.contains(saved[1].id) && midway.contains(saved[2].id),
                "the ones not yet picked up")

        await eventually("and by the end there is nothing left to say") {
            await core.stillResuming().isEmpty
        }
    }

    /// One runtime missing must not take the rest of the batch with it.
    @Test func oneFailureDoesNotStopTheRest() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let now = Date()
        let first = Agent(runtimeID: "grok", cwd: work, state: .running,
                          runtimeSessionID: "s", lastActivityAt: now)
        let broken = Agent(runtimeID: "copilot", cwd: work, state: .running,
                           runtimeSessionID: "s", lastActivityAt: now.addingTimeInterval(-60))
        let last = Agent(runtimeID: "cursor", cwd: work, state: .running,
                         runtimeSessionID: "s", lastActivityAt: now.addingTimeInterval(-120))
        for agent in [first, broken, last] { try await store.save(agent) }

        // Everything on this Mac except Copilot, which is the middle of the three.
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: RuntimeDiscovery(searchPaths: ["/fake/bin"],
                                                          fileExists: { !$0.hasSuffix("copilot") }),
                              launcher: FakeLauncher())
        await core.pickUpAfterRestart(await core.recover())

        await waitFor(core, first.id, "the one before it came back") { $0.state == .finished }
        await waitFor(core, last.id, "and so did the one after it") { $0.state == .finished }

        let page = try await core.transcript(.init(agentID: broken.id))
        #expect(page.entries.contains { ($0.text ?? "").contains("Could not pick this agent back up") },
                "and the one in the middle carries its own explanation")
    }

    /// Half a dozen runtimes starting at once is half a dozen node processes.
    @Test func theyAreStartedOneAtATime() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .milliseconds(200)
        // Long enough that no turn ends while the three are still starting. A turn that
        // ends without saying how it went is asked, and that question starts a runtime
        // of its own — which would land between two pick-ups and read as a short gap.
        script.turnDelay = .seconds(2)
        for _ in 0..<3 {
            try await store.save(Agent(runtimeID: "grok", cwd: work, state: .running,
                                       runtimeSessionID: "s", lastActivityAt: Date()))
        }

        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await eventually("all three were started") { launcher.launchCount == 3 }
        // Each launch waits on the handshake of the one before it. Concurrent starts
        // would land within a millisecond of each other rather than a handshake apart.
        #expect(launcher.gapsBetweenLaunches.allSatisfy { $0 >= .milliseconds(150) },
                "each one waited for the one before it: \(launcher.gapsBetweenLaunches)")
    }

    /// No loop guard (Alex, 2026-09-21): a chat cut off on the very turn it was brought
    /// back with is picked up again all the same. What used to be "left alone" was
    /// work abandoned by nobody, and a daemon restarted a few times in a row — every
    /// build of the app is one — left a trail of them.
    @Test func anAgentCutOffTwiceInARowIsPickedUpAgain() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let tried = Agent(runtimeID: "grok", cwd: work, state: .running,
                          runtimeSessionID: "s", restartPickUps: 1)
        try await store.save(tried)

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await eventually("it was started again") { launcher.launchCount == 1 }
        await eventually("and counted") { await core.agent(tried.id)?.restartPickUps == 2 }
    }

    /// Reaching the end of a turn is the whole of what the count asks about.
    @Test func aTurnThatEndsClearsTheCount() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s")
        try await store.save(wasRunning)

        let core = try core(FakeLauncher(), locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await waitFor(core, wasRunning.id, "it came back and finished") { $0.state == .finished }
        let after = await core.agent(wasRunning.id)
        #expect(after?.restartPickUps == 0, "counted to one on the way out, and back to nothing")
        #expect(after?.mayBePickedUpAfterRestart == false, "finished, so there is nothing to pick up")
    }

    /// Any ending but the daemon dying is evidence enough.
    @Test func anEndingThatIsNotAFinishAlsoClearsTheCount() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        var script = FakeACPAgent.Script()
        script.stopReason = "max_tokens"
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s")
        try await store.save(wasRunning)

        let core = try core(FakeLauncher(script: script), locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await waitFor(core, wasRunning.id, "it came back and ran out of room") {
            $0.endedReason == .maxTokens
        }
        let after = await core.agent(wasRunning.id)
        #expect(after?.restartPickUps == 0,
                "out of room is still a turn that got to its own end without taking the daemon")
    }

    /// The test that makes the guard survive a crash mid-pick-up: the count has to be
    /// on disk while the prompt is still in flight, not written after it lands.
    @Test func theCountIsWrittenBeforeTheWordsAreSent() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        var script = FakeACPAgent.Script()
        // Long enough that the pick-up is demonstrably still going while we read.
        script.handshakeDelay = .seconds(3)
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s")
        try await store.save(wasRunning)

        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        // The record on disk, which is the only thing the next daemon will read.
        let onDisk = try AgentStore(locations: locations)
        await eventually("the record already says it has been tried") {
            (try? await onDisk.load(wasRunning.id))?.agent.restartPickUps == 1
        }
        #expect(await core.agent(wasRunning.id)?.state == .stopped,
                "and the turn has not even begun, which is the point")
    }

    /// Endings somebody chose stay chosen.
    @Test func onlyInterruptedAgentsArePickedBackUp() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let running = Agent(runtimeID: "grok", cwd: work, state: .running, runtimeSessionID: "s")
        let asking = Agent(runtimeID: "grok", cwd: work, state: .waitingOnUser, runtimeSessionID: "s")
        let finished = Agent(runtimeID: "grok", cwd: work, state: .finished,
                             runtimeSessionID: "s", endedReason: .endTurn)
        let stopped = Agent(runtimeID: "grok", cwd: work, state: .stopped,
                            runtimeSessionID: "s", endedReason: .cancelled)
        let archived = Agent(runtimeID: "grok", cwd: work, state: .archived,
                             runtimeSessionID: "s", archivedReason: .byUser)
        for agent in [running, asking, finished, stopped, archived] { try await store.save(agent) }

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await waitFor(core, running.id, "the one that was working came back") { $0.state == .finished }
        await waitFor(core, asking.id, "and the one that was asking") { $0.state == .finished }
        try await Task.sleep(for: .milliseconds(300))
        // Two picked back up, and nothing else touched. Each of those two is then
        // asked how its turn went, which is a runtime apiece again.
        #expect(launcher.launchCount <= 4, "and nothing else was touched")
        #expect(launcher.launchCount >= 2)
        #expect(await core.agent(stopped.id)?.endedReason == .cancelled,
                "a chat somebody stopped stays stopped")
        #expect(await core.agent(archived.id)?.state == .archived)
    }

    /// That ending was already reported to the person at the time.
    @Test func anAgentWhoseProcessDiedIsNotPickedBackUp() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let died = Agent(runtimeID: "grok", cwd: work, state: .stopped,
                         runtimeSessionID: "s", endedReason: .processDied)
        try await store.save(died)

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        try await Task.sleep(for: .milliseconds(300))
        #expect(launcher.launchCount == 0)
        #expect(await core.agent(died.id)?.endedReason == .processDied)
    }

    /// `prompt` puts every prompt on the queue, so testing the queue was empty meant
    /// a chat somebody had typed at was silently never brought back at all.
    @Test func anAgentWithWordsAlreadyQueuedIsStillPickedBackUp() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running,
                               runtimeSessionID: "s",
                               queuedPrompts: [QueuedPrompt(text: "and then deploy it")])
        try await store.save(wasRunning)

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await eventually("it was picked back up") { launcher.launchCount == 1 }
    }

    /// The queued words were typed by somebody who believed the turn was still
    /// running. The news that it was not has to reach the agent first.
    @Test func theRestartWordsGoAheadOfWhatWasQueued() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        let wasRunning = Agent(runtimeID: "grok", cwd: work, state: .running,
                               runtimeSessionID: "s",
                               queuedPrompts: [QueuedPrompt(text: "and then deploy it")])
        try await store.save(wasRunning)

        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        await core.pickUpAfterRestart(await core.recover())

        await eventually("both prompts went") {
            guard let agent = await core.agent(wasRunning.id) else { return false }
            return agent.queuedPrompts.isEmpty && agent.state != .running
        }
        let page = try await core.transcript(.init(agentID: wasRunning.id))
        let prompts = page.entries.compactMap { entry -> String? in
            guard case .userMessage(let text, _, _) = entry.kind else { return nil }
            return text
        }
        let restart = prompts.firstIndex { $0.contains("The app restarted") }
        let queued = prompts.firstIndex { $0.contains("and then deploy it") }
        #expect(restart != nil && queued != nil, "both were sent: \(prompts)")
        if let restart, let queued {
            #expect(restart < queued, "the news first, then the instructions premised on it")
        }
    }

    /// Stop on a chat waiting to come back was a no-op that looked like it worked.
    @Test func stoppingAnAgentBeforeItIsPickedUpWithdrawsIt() async throws {
        let (locations, work) = try temporary()
        let store = try AgentStore(locations: locations)
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .milliseconds(500)
        let first = Agent(runtimeID: "grok", cwd: work, state: .running,
                          runtimeSessionID: "s", lastActivityAt: Date())
        let withdrawn = Agent(runtimeID: "grok", cwd: work, state: .running,
                              runtimeSessionID: "s", lastActivityAt: Date().addingTimeInterval(-60))
        for agent in [first, withdrawn] { try await store.save(agent) }

        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        await core.setConnectionCount(0)
        await core.pickUpAfterRestart(await core.recover())

        // While the first is still starting, stop the one behind it in the queue.
        // At least one, not exactly one: a turn that ends without saying how it went is
        // asked, and that question starts a runtime of its own.
        await eventually("the first is on its way") { launcher.launchCount >= 1 }
        try await core.stop(withdrawn.id)

        #expect(await core.stillResuming().contains(withdrawn.id) == false,
                "out of the queue at once, on the actor, with no await in between")
        let page = try await core.transcript(.init(agentID: withdrawn.id))
        #expect(page.entries.contains { ($0.text ?? "").contains("You stopped this agent before it was picked back up") })

        await eventually("the rest of the batch finished") {
            await core.agent(first.id)?.state == .finished
        }
        #expect(launcher.launchCount == 1, "and the one that was stopped never started")
        await eventually("and it holds no daemon open") { await core.shouldExit }
    }

    /// Only when there was in fact something to withdraw.
    @Test func anOrdinaryStopSaysNothingAboutPickingBackUp() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))

        await waitFor(core, id, "it is working") { $0.state == .running }
        try await core.stop(id)

        let page = try await core.transcript(.init(agentID: id))
        #expect(page.entries.contains { ($0.text ?? "").contains("before it was picked back up") } == false,
                "a normal stop does not gain a line about something that was never going to happen")
    }

    /// What the daemon said, for the tests that read its notifications.
    actor Broadcasts {
        private var sent: [(String, JSONValue?)] = []

        func record(_ method: String, _ params: JSONValue?) {
            sent.append((method, params))
        }

        /// The agents said to be joining the queue, or leaving it, in the order said.
        func resuming(_ isResuming: Bool) -> [UUID] {
            sent.compactMap { method, params in
                guard method == DaemonAPI.Notification.agentResuming,
                      let notification = try? params?.decode(DaemonAPI.ResumingNotification.self),
                      notification.isResuming == isResuming else { return nil }
                return notification.agentID
            }
        }
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

    /// The phone's list leaves them off archived agents, which were most of a 5.4 MB
    /// reply; the Mac's, whose archived chats still have a prompt bar, keeps them.
    @Test func aListCanLeaveThemOffArchivedAgentsOnly() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [commandsUpdate]
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        let kept = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        let archived = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        for id in [kept, archived] {
            await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        }
        try await core.archive(archived)

        func commands(_ request: DaemonAPI.ListRequest) async -> [UUID: [String]] {
            Dictionary(uniqueKeysWithValues: await core.listAgents(request).map {
                ($0.id, $0.availableCommands.map(\.name))
            })
        }
        #expect(await commands(.init())[archived] == ["review", "add-dir"])
        let phone = await commands(.init(archivedCommands: false))
        #expect(phone[kept] == ["review", "add-dir"])
        #expect(phone[archived] == [])
        #expect(await core.agent(archived)?.availableCommands.count == 2, "only the reply is trimmed")
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
            let onDisk = try? await AgentStore(locations: locations).load(id).agent
            return onDisk?.availableCommands.map(\.name) == ["review", "add-dir"] ? onDisk : nil
        }
        #expect(reread?.availableCommands.map(\.name) == ["review", "add-dir"])
    }
}
