import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A turn that ended and said nothing about itself.
///
/// The app asks once, and never again — the bound is what most of these are for. An
/// ending nobody accounted for is not a completion, and an agent that will not answer
/// must not be able to make the asking cost more than the endings themselves.
@Suite("An ending nobody accounted for", .timeLimit(.minutes(1)))
struct UnreportedEndingTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSilentTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A runtime whose turn lasts until the test opens `gate`.
    private static func held(_ gate: TurnGate) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.gate = gate
        return script
    }

    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(5), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if let agent = await core.agent(id),
               !agent.state.hasTurnInFlight, agent.queuedPrompts.isEmpty,
               await core.live[id] == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Every prompt on the record, with whose it was. This is the count SC-009 is
    /// about: the number of questions must never exceed the number of endings.
    private func prompts(_ core: DaemonCore, _ id: UUID) async throws -> [(String, PromptOrigin)] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry in
            if case .userMessage(let text, _, let from) = entry.kind { return (text, from) }
            return nil
        }
    }

    private func asks(_ core: DaemonCore, _ id: UUID) async throws -> Int {
        try await prompts(core, id).count { $0.1 == .app }
    }

    // MARK: Asked, once

    @Test func aTurnThatSaidNothingIsAskedExactlyOnce() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("the question was asked") { await core.agent(id)?.outcomeAsked == true }
        try await settle(core, id)
        #expect(try await asks(core, id) == 1)
        // Visibly the app's, and never attributed to the person.
        let asked = try await prompts(core, id).first { $0.1 == .app }
        #expect(asked?.0.contains(AppTool.finishTurn) == true)
        #expect(await core.agent(id)?.outcomeAsked == true)
    }

    /// The ask names `finish_turn`; an agent answers it by that name or, if it was
    /// briefed before 023, by `report_outcome`. The older name is
    /// `anAnsweredQuestionLeavesNothingMarkingItAsHavingBeenAsked` above; this is the
    /// new one, and the ending is accounted for either way (FR-018).
    @Test func anAnswerByEitherNameAccountsForTheEnding() async throws {
        let (locations, work) = try temporary()
        // The asked turn is the second runtime: held, so it is answered in the middle.
        let asked = TurnGate()
        let launcher = FakeLauncher(script: .init(), then: [.init(), Self.held(asked)])
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("the question was asked") { await core.agent(id)?.outcomeAsked == true }
        let token = await eventuallySome("the asked turn has a token of its own") {
            guard await core.agent(id)?.state == .running else { return nil }
            return await core.appTokens.first { $0.value == id }?.key
        } ?? ""
        _ = try await core.finishTurn(.init(token: token, outcome: "done",
                                            message: "Renamed 14 call sites.",
                                            prompts: [.init(label: "Push", prompt: "Push it")]))
        asked.open()
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .done)
        #expect(agent.suggestedPrompts.map(\.label) == ["Push"])
        #expect(agent.endingIsUnaccountedFor == false)
        #expect(try await asks(core, id) == 1)
    }

    /// The ask names the one tool a fresh conversation was told about, and neither of
    /// the older names — an agent briefed with those answers by them all the same,
    /// because the aliases are accepted everywhere (023, FR-018).
    @Test func theQuestionNamesTheOneTool() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("the question was asked") { await core.agent(id)?.outcomeAsked == true }
        try await settle(core, id)
        let asked = try #require(try await prompts(core, id).first { $0.1 == .app }?.0)
        #expect(asked.contains(AppTool.finishTurn))
        #expect(!asked.contains(AppTool.reportOutcome))
        #expect(!asked.contains(AppTool.suggestPrompts))
    }

    /// SC-009, counted. The turn the question causes comes back through the same
    /// place, finds the flag set, and stops. That is the whole of the bound.
    @Test func theQuestionIsNeverAskedASecondTime() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("the question was asked") { await core.agent(id)?.outcomeAsked == true }
        try await settle(core, id)
        // Long enough for a second question to have been asked if one were coming.
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await asks(core, id) == 1)

        let agent = try #require(await core.agent(id))
        // Left honestly: not accounted for, still under Complete, and no colour.
        #expect(agent.endingIsUnaccountedFor)
        #expect(agent.report == nil)
        #expect(agent.group(wantsEyes: false) == .finished)
        #expect(agent.needsAPerson == false)
    }

    /// An agent that answers is indistinguishable from one that reported first time.
    @Test func anAnsweredQuestionLeavesNothingMarkingItAsHavingBeenAsked() async throws {
        let (locations, work) = try temporary()
        // The asked turn held open, to be answered in the middle of, which is when a
        // real agent answers: the daemon lets the runtime go the moment a turn ends.
        let asked = TurnGate()
        let launcher = FakeLauncher(script: .init(), then: [.init(), Self.held(asked)])
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        // The flag goes up before the prompt is enqueued, and the turn that prompt
        // causes mints a token of its own — a resumed session is a new process, so the
        // old token stopped working when the last one died.
        await eventually("the question was asked") { await core.agent(id)?.outcomeAsked == true }
        let token = await eventuallySome("the asked turn has a token of its own") {
            guard await core.agent(id)?.state == .running else { return nil }
            return await core.appTokens.first { $0.value == id }?.key
        } ?? ""
        _ = try await core.reportOutcome(.init(token: token, outcome: "done",
                                               message: "Renamed 14 call sites."))
        asked.open()

        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .done)
        // Nothing about it reads as an agent that had to be asked.
        #expect(agent.endingIsUnaccountedFor == false)
        #expect(agent.group(wantsEyes: false) == .finished)
    }

    // MARK: When nothing is asked at all

    /// A prompt from the person supersedes the ask for the ending it overtook: they
    /// have moved the work on, and asking an agent to account for a turn they have
    /// already superseded is noise (FR-023).
    ///
    /// The turn *their* prompt causes is a different ending, and gets its own one
    /// question — which is the whole point of the bound being per ending.
    /// What 019's grouping reads, held where it is set. The daemon changes nothing
    /// for 019: the flag goes up before the question is enqueued and only a person's
    /// prompt takes it down, so `running && outcomeAsked` is the question and nothing
    /// else. This holds both facts the way the plan says they already are, and that
    /// the grouping keeps the agent where it was for as long as they hold.
    @Test func theQuestionIsAskedWithTheFlagUpAndAPromptTakesItDown() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(300)
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("the question was asked") { await core.agent(id)?.outcomeAsked == true }
        let asked = try #require(await core.agent(id))
        #expect(asked.outcomeAsked)
        // Whether the question's turn is still in flight or already over, the group is
        // the one it had before the app spoke (US3-1, US3-5).
        #expect(asked.group(wantsEyes: false) == .finished)

        // A person's prompt is work they asked for: the flag comes down at once, and
        // with it the agent is Working (US3-4).
        try await core.prompt(.init(agentID: id, text: "carry on"))
        #expect(await core.agent(id)?.outcomeAsked == false)
        try await settle(core, id)
    }

    @Test func theEndingAPersonsPromptOvertookIsNotAskedAbout() async throws {
        let (locations, work) = try temporary()
        let first = TurnGate()
        let core = try core(FakeLauncher(script: .init(), then: [Self.held(first)]), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        // Queued while the first turn is still in flight, so it is waiting when that
        // turn ends and the gate is shut.
        try await core.prompt(.init(agentID: id, text: "something else entirely"))
        first.open()
        try await settle(core, id)
        // The question comes a moment after the ending it is about, and may start a
        // runtime of its own; 200 ms was a bet on that moment.
        await settled(core, id, "the question about the second ending was asked and answered")

        // In order: their first prompt, their second, and then one question about the
        // ending that one caused. Nothing was asked about the ending in between.
        let said = try await prompts(core, id)
        #expect(said.map(\.1) == [.person, .person, .app])
        #expect(said.count { $0.1 == .app } == 1)
    }

    /// FR-025. A turn that ended short keeps its own wording, and nothing is expected
    /// or implied for it.
    @Test func aTurnThatEndedShortIsNeverAskedAbout() async throws {
        for stop in ["cancelled", "max_tokens", "refusal"] {
            let (locations, work) = try temporary()
            var script = FakeACPAgent.Script()
            script.stopReason = stop
            let core = try core(FakeLauncher(script: script), locations: locations)
            let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

            try await settle(core, id)
            try await Task.sleep(for: .milliseconds(150))

            #expect(try await asks(core, id) == 0, "\(stop) was asked about")
            let agent = try #require(await core.agent(id))
            #expect(agent.outcomeAsked == false)
            #expect(agent.endingIsUnaccountedFor == false)
            // The existing wording for that ending is what is shown, unchanged.
            #expect(agent.endedReason?.summary != nil)
        }
    }

    /// An archived agent is not asked, and is not in Needs attention whatever it says.
    @Test func anArchivedAgentIsNotAsked() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(script: Self.held(TurnGate())), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("it is working") { await core.agent(id)?.state == .running }
        try await core.archive(id)
        try await Task.sleep(for: .milliseconds(400))

        #expect(try await asks(core, id) == 0)
        #expect(await core.agent(id)?.state == .archived)
    }

    /// FR-026. Where an agent reported and then ended short anyway, both are on the
    /// record: how it ended, and what it last said about the work.
    @Test func aReportAndAShortEndingAreBothKept() async throws {
        let (locations, work) = try temporary()
        let turn = TurnGate()
        var script = Self.held(turn)
        script.stopReason = "max_tokens"
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let token = await eventuallySome("the runtime was handed its token") {
            let attached = await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue ?? []
            let minted = attached.first?["args"]?.arrayValue?.last?.stringValue ?? ""
            return minted.isEmpty ? nil : minted
        } ?? ""
        _ = try await core.reportOutcome(.init(token: token, outcome: "partly_done",
                                               message: "Five of six."))
        turn.open()
        try await settle(core, id)

        let agent = try #require(await core.agent(id))
        #expect(agent.endedReason == .maxTokens)
        #expect(agent.report?.outcome == .partlyDone)
        // And the ending short is not asked about, whatever the agent said.
        #expect(try await asks(core, id) == 0)
    }

    /// FR-024. A turn the app started on its own is never spending the person cannot
    /// see: it is recorded and counted like any other.
    @Test func whatTheQuestionCostsIsCountedLikeAnyOtherTurn() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.usage = ["inputTokens": 10, "outputTokens": 5]
        let core = try core(FakeLauncher(script: script), locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await eventually("the question was asked") { await core.agent(id)?.outcomeAsked == true }
        try await settle(core, id)
        let usages = try await core.transcript(.init(agentID: id)).entries
            .count { if case .usageRecorded = $0.kind { return true } else { return false } }
        // Two turns, two usage lines: the person's prompt, and the app's question.
        #expect(usages == 2)
    }
}
