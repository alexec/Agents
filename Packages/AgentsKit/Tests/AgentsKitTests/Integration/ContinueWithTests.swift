import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// US5 of 052: a chat moves to another runtime by hand, with every setting shown and
/// chosen, and the same sheet changes what an automatic switch carried on with.
@Suite("Continue with another runtime", .timeLimit(.minutes(1)))
struct ContinueWithTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan"))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))

    private func offering(modes: [String], current: String, models: [String]) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.configOptions = [
            ConfigOption(id: "permission_mode", name: "Mode", category: "mode", type: "select",
                         currentValue: .string(current),
                         options: modes.map { ConfigChoice(value: .string($0), name: $0) }),
            ConfigOption(id: "llm", name: "Model", category: "model", type: "select",
                         currentValue: .string(models[0]),
                         options: models.map { ConfigChoice(value: .string($0), name: $0) }),
        ]
        return script
    }

    private var claudeScript: FakeACPAgent.Script {
        offering(modes: ["default", "acceptEdits"], current: "default", models: ["opus", "sonnet"])
    }

    private var codexScript: FakeACPAgent.Script {
        offering(modes: ["read-only", "agent", "agent-full-access"], current: "agent", models: ["gpt-5", "gpt-5-codex"])
    }

    /// Launches play `first` in order, then Codex's options for ever after.
    private func core(_ first: [FakeACPAgent.Script]) async throws -> (DaemonCore, URL, FakeLauncher) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContinueWith-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        let current = locations.tools.appendingPathComponent("codex/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        discovery.macToolsHome = locations.tools.path
        let launcher = FakeLauncher(script: codexScript, then: first)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex]))
        return (core, work, launcher)
    }

    /// A chat on Claude whose turn, and the app's ask for a report after it, are over.
    private func quietClaudeChat() async throws -> (DaemonCore, UUID, URL, FakeLauncher) {
        let (core, work, launcher) = try await core([claudeScript, claudeScript])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "fix the redirect"))
        await eventually("the chat is quiet", within: .seconds(30)) {
            let agent = await core.agent(id)
            let endings = (try? await core.transcript(.init(agentID: id)).entries.count {
                if case .stateChanged(.finished, _) = $0.kind { true } else { false }
            }) ?? 0
            return agent?.outcomeAsked == true && agent?.state == .finished && endings == 2 && launcher.launchCount == 2
        }
        return (core, id, work, launcher)
    }

    private func failure(_ body: () async throws -> Void) async -> JSONRPCError? {
        do { try await body(); return nil } catch let error as JSONRPCError { return error } catch { return nil }
    }

    @Test func thePreviewShowsThePlanAndChangesNothing() async throws {
        let (core, id, work, launcher) = try await quietClaudeChat()
        // Codex has run in this folder once, so what it offers here is remembered.
        let other = try await core.start(.init(runtimeID: "codex", cwd: work, prompt: "hello"))
        await eventually("Codex answered") { await core.agent(other)?.state == .finished }
        let launches = launcher.launchCount

        let preview = try await core.continueWith(.init(agentID: id, runtimeID: "codex"))
        #expect(preview.runtimeID == "codex")
        #expect(preview.options.map(\.id).sorted() == ["llm", "permission_mode"])
        // Claude's `default` has one place on the scale: Codex's `read-only`.
        #expect(preview.plan.values["permission_mode"] == .string("read-only"))
        #expect(preview.plan.rows.first { $0.optionID == "permission_mode" }?.source == .closestNoLooser)
        #expect(await core.agent(id)?.runtimeID == "claude")
        #expect(launcher.launchCount == launches)
    }

    @Test func applyingMovesItWithTheChosenValuesAndSendsNothingUntilTheNextPrompt() async throws {
        let (core, id, _, launcher) = try await quietClaudeChat()
        let result = try await core.continueWith(.init(agentID: id, runtimeID: "codex",
                                                       choices: ["llm": "gpt-5-codex", "permission_mode": "read-only"],
                                                       confirmed: true))
        let agent = try #require(result.agent)
        #expect(agent.runtimeID == "codex")
        #expect(agent.poolEntryID == codex.id)
        #expect(agent.startOptions.values["llm"] == .string("gpt-5-codex"))
        #expect(agent.startOptions.values["permission_mode"] == .string("read-only"))
        let kinds = try await core.transcript(.init(agentID: id)).entries.map(\.kind)
        let record = try #require(kinds.compactMap { if case .poolSwitch(let r) = $0 { r } else { nil } }.last)
        #expect(record.reason == .byHand)
        #expect(record.carried.first { $0.optionID == "llm" }?.source == .person)
        #expect(await core.eventLog.events.contains { $0.name == "agent.runtime_switched" && $0.details["reason"] == "byHand" })

        // Nothing sent yet.
        let codexRuntime = try #require(launcher.allAgents.last)
        #expect(await codexRuntime.prompts.isEmpty)

        // The next prompt carries the handoff, then the words.
        try await core.prompt(.init(agentID: id, text: "carry on"))
        await eventually("Codex was prompted") { await !codexRuntime.prompts.isEmpty }
        let sent = await codexRuntime.prompts.first?.arrayValue ?? []
        let text = sent.compactMap { $0["text"]?.stringValue ?? $0["resource"]?["text"]?.stringValue }.joined(separator: "\n")
        #expect(text.contains("# Conversation so far"))
        #expect(text.contains("fix the redirect"))
        #expect(text.contains("carry on"))
    }

    @Test func notWhileATurnIsRunning() async throws {
        var slow = claudeScript
        slow.turnDelay = .seconds(5)
        let (core, work, _) = try await core([slow])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn is running") { await core.agent(id)?.state == .running }
        let error = await failure { _ = try await core.continueWith(.init(agentID: id, runtimeID: "codex", confirmed: true)) }
        #expect(error?.code == DaemonAPI.Failure.stopTheTurnFirst)
        #expect(error?.message == "Stop the turn first.")
        #expect(await core.agent(id)?.runtimeID == "claude")
        try await core.stop(id)
    }

    @Test func aLooserModeIsRefused() async throws {
        let (core, id, _, _) = try await quietClaudeChat()
        let error = await failure {
            _ = try await core.continueWith(.init(agentID: id, runtimeID: "codex",
                                                  choices: ["permission_mode": "agent-full-access"], confirmed: true))
        }
        #expect(error?.code == -32602)
        #expect(error?.message.contains("cannot be looser than the chat's own, default") == true)
        #expect(await core.agent(id)?.runtimeID == "claude")
    }

    @Test func aValueTheRuntimeDoesNotOfferIsRefused() async throws {
        let (core, id, _, _) = try await quietClaudeChat()
        let error = await failure {
            _ = try await core.continueWith(.init(agentID: id, runtimeID: "codex", choices: ["llm": "opus"], confirmed: true))
        }
        #expect(error?.message == "Codex does not offer opus for Model.")
        #expect(await core.agent(id)?.runtimeID == "claude")
    }

    @Test func adjustingAnAutomaticSwitchChangesTheNextTurnOnly() async throws {
        var spent = claudeScript
        spent.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        let (core, work, launcher) = try await core([spent])
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it moved to Codex") { await core.agent(id)?.runtimeID == "codex" }
        await eventually("Codex answered") { await core.agent(id)?.state == .finished }
        let launches = launcher.launchCount

        let preview = try await core.continueWith(.init(agentID: id, adjust: true))
        #expect(preview.runtimeID == "codex")
        #expect(preview.options.map(\.id).sorted() == ["llm", "permission_mode"])

        let adjusted = try await core.continueWith(.init(agentID: id, adjust: true, choices: ["llm": "gpt-5"], confirmed: true))
        #expect(adjusted.agent?.startOptions.values["llm"] == .string("gpt-5"))
        #expect(await core.agent(id)?.runtimeID == "codex")
        #expect(launcher.launchCount == launches, "no new session")
        #expect(try await core.transcript(.init(agentID: id)).entries.contains {
            if case .settingsChanged = $0.kind { true } else { false }
        })
        // Never looser than the mode the chat had before it moved.
        let looser = await failure {
            _ = try await core.continueWith(.init(agentID: id, adjust: true, choices: ["permission_mode": "agent"], confirmed: true))
        }
        #expect(looser?.message.contains("cannot be looser") == true)
    }

    @Test func aPairedPhoneMayDoItToo() {
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.agentsContinueWith))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.agentsSetSwitching))
    }

    @Test func theChatsOwnSwitchIsSetAndRead() async throws {
        let (core, id, _, _) = try await quietClaudeChat()
        await core.setSwitching(agentID: id, off: true)
        #expect(await core.agent(id)?.switchingOff == true)
        await core.setSwitching(agentID: id, off: false)
        #expect(await core.agent(id)?.switchingOff == false)
    }
}
