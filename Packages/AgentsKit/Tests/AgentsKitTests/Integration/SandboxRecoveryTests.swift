import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A sandbox that could not be set up stops the agent with the card, in each of its three
/// shapes, and only the person's answer carries on without it (064, US1, R11, R12).
@Suite("Sandbox recovery", .timeLimit(.minutes(1)))
struct SandboxRecoveryTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSandboxRecovery-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func makeCore(_ locations: StoreLocations, _ launcher: FakeLauncher) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/sandbox-failures/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A shell command that finished, printing `output`.
    private func command(_ id: String, printing output: String) -> [JSONValue] {
        [["sessionUpdate": "tool_call", "toolCallId": .string(id), "title": "Run a command",
          "kind": "execute", "status": "in_progress", "content": []],
         ["sessionUpdate": "tool_call_update", "toolCallId": .string(id), "status": "completed", "kind": "execute",
          "content": [["type": "content", "content": ["type": "text", "text": .string(output)]]]]]
    }

    private func cards(_ core: DaemonCore, _ id: UUID) async throws -> [SandboxFailureRecord] {
        try await core.store.transcript(for: id, limit: 500).entries.compactMap {
            if case .sandboxFailure(let record) = $0.kind { return record }
            return nil
        }
    }

    @Test func aCommandWhoseSandboxFailedStopsTheAgentWhenTheTurnEnds() async throws {
        let (locations, work) = try temporary()
        var clean = FakeACPAgent.Script()
        clean.supportsResume = true
        var script = clean
        script.updates = command("t1", printing: try fixture("claude-macos-nested-seatbelt"))
            + [FakeACPAgent.chunk("The sandbox failed to start.")]
        // Fails once, as a host would; every launch after is a runtime that works.
        let launcher = FakeLauncher(script: clean, then: [script])
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "Build it", sandbox: .on))

        await eventually("the agent stopped") { await core.agent(id)?.state == .stopped }
        let agent = try #require(await core.agent(id))
        #expect(agent.endedReason == .sandboxFailed)
        #expect(agent.pendingSandboxFailure?.recoveryOffered == true)
        #expect(agent.pendingSandboxFailure?.completedToolCalls == 0, "the failed command did not run")
        #expect(try await cards(core, id).count == 1)

        // Nothing carries on by itself (SC-009).
        try await Task.sleep(for: .milliseconds(300))
        #expect(launcher.launchCount == 1)
        #expect(await core.agent(id)?.state == .stopped)

        // Continue without sandbox: this agent is Off, and the prompt goes again.
        _ = try await core.answerSandbox(.init(agentID: id, carryOn: true))
        await eventually("it ran again") { launcher.launchCount == 2 }
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        #expect(await core.agent(id)?.sandboxOverride == .off)
        #expect(await core.agent(id)?.pendingSandboxFailure == nil)
        let again = launcher.allAgents[1]
        let resent = await again.prompts.first
        #expect(resent.map { "\($0)".contains("Build it") } == true, "the person's words, not retyped")
        let continued = await again.continuedSessionParams
        #expect(continued?["_meta"]?["claudeCode"]?["options"]?["sandbox"]?["enabled"] == .bool(false))
        await #expect(throws: JSONRPCError.self) { _ = try await core.answerSandbox(.init(agentID: id, carryOn: true)) }
    }

    @Test func keepStoppedLeavesItStopped() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = command("t1", printing: try fixture("claude-macos-nested-seatbelt"))
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "Build it", sandbox: .on))
        await eventually("the agent stopped") { await core.agent(id)?.state == .stopped }
        _ = try await core.answerSandbox(.init(agentID: id, carryOn: false))
        #expect(await core.agent(id)?.pendingSandboxFailure == nil)
        #expect(await core.agent(id)?.state == .stopped)
        #expect(await core.agent(id)?.sandboxOverride == .on, "nothing widened")
        #expect(launcher.launchCount == 1)
    }

    @Test func afterCommandsRanItAsksToCarryOnRatherThanRepeating() async throws {
        let (locations, work) = try temporary()
        var clean = FakeACPAgent.Script()
        clean.supportsResume = true
        var script = clean
        script.updates = command("t0", printing: "built")
            + command("t1", printing: try fixture("claude-macos-nested-seatbelt"))
        let launcher = FakeLauncher(script: clean, then: [script])
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "Build it", sandbox: .on))
        await eventually("the agent stopped") { await core.agent(id)?.state == .stopped }
        #expect(await core.agent(id)?.pendingSandboxFailure?.completedToolCalls == 1)
        _ = try await core.answerSandbox(.init(agentID: id, carryOn: true))
        await eventually("it ran again") { launcher.launchCount == 2 }
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        let sent = await launcher.allAgents[1].prompts.first.map { "\($0)" } ?? ""
        #expect(sent.contains("The command sandbox is now off"))
    }

    @Test func codexSaysItOnlyInItsReply() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [FakeACPAgent.chunk("I’ll run it. sandbox-exec: sandbox_apply: "),
                          FakeACPAgent.chunk("Operation not permitted")]
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "Build it"))
        await eventually("the agent stopped") { await core.agent(id)?.state == .stopped }
        #expect(await core.agent(id)?.endedReason == .sandboxFailed)
    }

    @Test func aCommandDeniedInsideAWorkingSandboxIsJustAFailedCommand() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = command("t1", printing: try fixture("not-claude-denied-inside-sandbox"))
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "Build it", sandbox: .on))
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
        #expect(await core.agent(id)?.pendingSandboxFailure == nil)
        #expect(try await cards(core, id).isEmpty)
    }

    @Test func aNewAgentWhoseSandboxWillNotStartIsRefusedWithTheWords() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.newSessionError = JSONRPCError(code: -32603, message: "Internal error",
                                              data: ["details": .string(try fixture("claude-linux-missing-bwrap"))])
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        do {
            _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "Build it", sandbox: .on))
            Issue.record("it started")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.sandboxWillNotStart)
            let data = try #require(try error.data?.decode(DaemonAPI.SandboxWillNotStart.self))
            #expect(data.offOffered)
            #expect(data.detail.hasPrefix("Claude Code returned an error result: Sandbox required but unavailable"))
        }
        #expect(await core.allAgents().isEmpty, "the form keeps the prompt; no agent")
    }

    @Test func aPickUpWhoseSandboxWillNotStartStopsWithTheCardAndKeepsThePrompt() async throws {
        let (locations, work) = try temporary()
        var first = FakeACPAgent.Script()
        first.supportsResume = true
        var refusing = first
        // Refused both ways: the resume, and the new conversation the app falls back to.
        let refusal = JSONRPCError(code: -32603, message: "Internal error",
                                   data: ["details": .string(try fixture("claude-linux-missing-bwrap"))])
        refusing.sessionGoneError = refusal
        refusing.newSessionError = refusal
        // The first turn ends short, so the app asks nothing after it and the next
        // launch is the one refused.
        var short = first
        short.stopReason = "refusal"
        let launcher = FakeLauncher(script: first, then: [short, refusing])
        let core = try await makeCore(locations, launcher)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "one"))
        await eventually("the turn ended") { await core.agent(id)?.state == .stopped }
        await eventually("its runtime was handed back") { await core.live[id] == nil }
        _ = try await core.setSandbox(.init(agentID: id, choice: .on))

        try? await core.prompt(.init(agentID: id, text: "two"))
        await eventually("the agent stopped") { await core.agent(id)?.endedReason == .sandboxFailed }
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["two"], "what was typed is kept")
        _ = try await core.answerSandbox(.init(agentID: id, carryOn: true))
        await eventually("it went") { await core.agent(id)?.queuedPrompts.isEmpty == true }
    }

    @Test func geminiThatNeverAnswersIsItsSandboxHanging() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .seconds(30)
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        await core.setSandboxHangDeadline(.milliseconds(200))
        try await core.lendCredential(.init(runtime: "gemini", secret: try #require(Secret(LendTests.geminiKey))),
                                      connection: nil)
        do {
            _ = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "Build it"))
            Issue.record("it started")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.sandboxWillNotStart)
        }
    }

    @Test func geminiOffIsNeverTakenForAHang() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.handshakeDelay = .milliseconds(400)
        let launcher = FakeLauncher(script: script)
        let core = try await makeCore(locations, launcher)
        await core.setSandboxHangDeadline(.milliseconds(100))
        try await core.lendCredential(.init(runtime: "gemini", secret: try #require(Secret(LendTests.geminiKey))),
                                      connection: nil)
        let id = try await core.start(.init(runtimeID: "gemini", cwd: work, prompt: "Build it", sandbox: .off))
        await eventually("the turn ended") { await core.agent(id)?.state == .finished }
    }
}
