import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One model failing is that model's, not its runtime's (#140).
///
/// The assessment found OpenCode out of the pool for four hours because one free
/// model's endpoint was down, while its default model worked. A provider's failure now
/// marks the model; and a runtime marked out comes back as soon as a turn on it is
/// answering, so the agent proving it works can start a helper on it in that turn.
@Suite("A model's failure, not the runtime's", .timeLimit(.minutes(1)))
struct ModelFailureTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsModelFailure-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work.resolvingSymlinksInPath()))
    }

    private func makeCore(_ locations: StoreLocations, _ launcher: FakeLauncher) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    /// OpenCode's menu as the assessment found it: a free model first, its default second.
    private var models: [ConfigOption] {
        [ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                      currentValue: .string("opencode/ling-3.0-flash-fin-free"),
                      options: [ConfigChoice(value: .string("opencode/ling-3.0-flash-fin-free"), name: "Ling 3.0 Flash"),
                                ConfigChoice(value: .string("opencode/big-pickle"), name: "Big Pickle")])]
    }

    private func state(_ core: DaemonCore) async -> AllowanceState? {
        await core.allowanceStates().first { $0.credentialKey == "opencode:sign-in" }
    }

    @Test func anUpstreamFailureMarksTheModelAndLeavesTheRuntimeIn() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.configOptions = models
        script.promptError = JSONRPCError(code: -32603, message: "Upstream request failed: Endpoint is unavailable")
        let core = try await makeCore(locations, FakeLauncher(script: script))

        let id = try await core.start(.init(runtimeID: "opencode", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.state.hasTurnInFlight == false }
        await eventually("the model is marked") { await state(core)?.modelsOut != nil }

        let marked = try #require(await state(core))
        #expect(!marked.isOut)
        #expect(marked.modelsOut?.map(\.model) == ["opencode/ling-3.0-flash-fin-free"])
        #expect(await core.whyUnavailable("opencode") == nil)
        // Said wherever the runtime is chosen: the Pool page's line, the web's runtime
        // list, and what an agent reads before it names one.
        let line = try #require(await core.runtimeAllowances().rows.first { $0.runtimeID == "opencode" })
            .line(now: Date())
        #expect(line.hasPrefix("Available · Model Ling 3.0 Flash out since "))
        #expect(await core.runtimeStatuses().first { $0.id == "opencode" }?.poolNote?.contains("Ling 3.0 Flash") == true)
        // A model out is not the runtime out: the page's chooser keeps it in Available (#257).
        #expect(await core.runtimeStatuses().first { $0.id == "opencode" }?.isOut == nil)
        let choices = await core.runtimeChoices(in: work)
        #expect(choices.contains("; Model Ling 3.0 Flash out since "), "\(choices)")
        #expect(!choices.contains("Not available on this Mac: opencode"))
        #expect(await core.eventLog.events.contains { $0.name == "cost.allowance_out" } == false)
    }

    @Test func anUnrecognisedFailureStillTakesTheRuntimeOut() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.configOptions = models
        script.promptError = JSONRPCError(code: -32603, message: "Internal error")
        let core = try await makeCore(locations, FakeLauncher(script: script))

        let id = try await core.start(.init(runtimeID: "opencode", cwd: work, prompt: "go"))
        await eventually("the turn ended") { await core.agent(id)?.state.hasTurnInFlight == false }
        await eventually("opencode is out") { await state(core)?.isOut == true }
        #expect(await state(core)?.modelsOut == nil)
        // And said with the runtime, for a chooser with no allowances of its own (#257).
        #expect(await core.runtimeStatuses().first { $0.id == "opencode" }?.isOut == true)
    }

    @Test func aFailureOnOneModelThenAWorkingTurnOnAnotherStartsAHelperWithinThatTurn() async throws {
        let (locations, work) = try temporary()
        var failing = FakeACPAgent.Script()
        failing.configOptions = models
        failing.promptError = JSONRPCError(code: -32603, message: "Upstream request failed: Endpoint is unavailable")
        var working = FakeACPAgent.Script()
        working.configOptions = models
        // Long enough to call start_agent while the turn is still running.
        working.turnDelay = .seconds(3)
        let core = try await makeCore(locations, FakeLauncher(script: working, then: [failing]))

        // The free model fails: the model is marked.
        let failed = try await core.start(.init(runtimeID: "opencode", cwd: work, prompt: "go"))
        await eventually("the first turn ended") { await core.agent(failed)?.state.hasTurnInFlight == false }
        await eventually("the model is marked") { await state(core)?.modelsOut != nil }
        // And, as before #140, the runtime marked out by something else: the hardest case
        // for a turn that works.
        await core.runtimeFailed(runtimeID: "opencode")
        #expect(await core.whyUnavailable("opencode") != nil)

        // A turn on the default model, still running, calls start_agent for OpenCode.
        let lead = try await core.start(.init(runtimeID: "opencode", cwd: work, prompt: "Lead",
                                              startOptions: StartOptions(values: ["model": .string("opencode/big-pickle")])))
        await eventually("the lead is working") { await core.agent(lead)?.state.hasTurnInFlight == true }
        let token = UUID().uuidString
        await core.bindAppToken(token, to: lead)
        let answer = await core.handle(method: DaemonAPI.Method.agentsStartHelper,
                                       params: try JSONValue.encoding(DaemonAPI.StartHelperRequest(
                                           token: token, prompt: "Count the files", runtime: "opencode")))

        guard case .success = answer else { Issue.record("start_agent was refused: \(answer)"); return }
        #expect(await core.agent(lead)?.state.hasTurnInFlight == true)
        #expect(await state(core)?.isOut == false)
        #expect(await core.eventLog.events.contains {
            $0.name == "cost.allowance_back" && $0.details["how"] == "answering"
        })
        // The free model stays marked: nothing has worked on it.
        #expect(await state(core)?.modelsOut?.map(\.model) == ["opencode/ling-3.0-flash-fin-free"])
    }
}
