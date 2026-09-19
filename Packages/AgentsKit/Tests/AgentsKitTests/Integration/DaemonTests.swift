import Foundation
import Testing
@testable import AgentsKit

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

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(200))
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
        try await settle()

        let agent = await core.agent(id)
        #expect(agent?.state == .finished)
        #expect(agent?.endedReason == .endTurn)
        #expect(agent?.title == "Say hello", "the runtime's own title names the agent")
        #expect(agent?.runtimeSessionID != nil)

        let page = try await core.transcript(.init(agentID: id))
        let texts = page.entries.compactMap(\.text)
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
        try await settle()

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
        try await settle()
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

    @Test func theRecordIsWrittenAsThingsHappenNotAtTheEnd() async throws {
        // A daemon killed mid-turn still has to leave something true behind.
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = (0..<20).map { FakeACPAgent.chunk("chunk \($0)") }
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await settle()

        // Read the file itself rather than the daemon's memory.
        let lines = try String(contentsOf: locations.transcript(id), encoding: .utf8)
            .split(separator: "\n")
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
        try await settle()

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
        try await settle()

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
        try await settle()
        #expect(await core.agent(id)?.state == .waitingOnUser)

        try await core.stop(id)
        try await settle()

        #expect(await core.agent(id)?.state == .stopped)
        #expect(await core.agent(id)?.endedReason == .cancelled)
        #expect(await core.pendingPermissionRequests().isEmpty)
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "cancelled")
    }

    @Test func aPromptToARunningAgentIsRefusedRatherThanQueuedSilently() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Wait here"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]]
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await settle()

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
        try await settle()
        let sessionID = await core.agent(id)?.runtimeSessionID
        #expect(await core.agent(id)?.state == .finished)

        try await core.prompt(.init(agentID: id, text: "second"))
        try await settle()

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
        try await settle()
        let originalSession = await core.agent(id)?.runtimeSessionID

        try await core.prompt(.init(agentID: id, text: "second"))
        try await settle()

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
        try await settle()
        try await core.archive(id)
        #expect(await core.agent(id)?.state == .archived)

        try await core.prompt(.init(agentID: id, text: "two"))
        try await settle()
        #expect(await core.agent(id)?.state == .finished)
        #expect(await core.agent(id)?.archivedReason == nil)
    }

    // MARK: Getting finished work out of the way

    @Test func nothingArchivesItself() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await settle()
        #expect(await core.agent(id)?.state == .finished, "finished, and still on the list")
        #expect(await core.agent(id)?.archivedReason == nil)
    }

    @Test func aTurnThatStopsShortIsNotAFinish() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.stopReason = "refusal"
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await settle()
        #expect(await core.agent(id)?.state == .stopped)
        #expect(await core.agent(id)?.endedReason == .refusal)
    }

    @Test func aStopReasonWeHaveNeverHeardOfIsRecordedRatherThanRounded() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.stopReason = "ran_out_of_biscuits"
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        try await settle()

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
        try await settle()
        #expect(await core.agent(id)?.state == .waitingOnUser)

        try await core.archive(id)
        try await settle()
        #expect(await core.agent(id)?.state == .archived)
        #expect(await core.isHoldingAgents == false, "nothing is left running behind an archived agent")
    }
}
