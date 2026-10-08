import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A turn that ended and said nothing about itself (#479).
///
/// Nothing is asked: the app works the ending out from how the turn stopped, whether a
/// question is open, and the agent's closing words. A `finish_turn` call still wins.
@Suite("An ending the agent did not account for", .timeLimit(.minutes(1)))
struct DerivedEndingTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDerivedTests-\(UUID().uuidString)", isDirectory: true)
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

    private static func saying(_ words: String...) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.updates = words.map { FakeACPAgent.chunk($0, messageID: "m1") }
        return script
    }

    private func prompts(_ core: DaemonCore, _ id: UUID) async throws -> [(String, PromptOrigin)] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry in
            if case .userMessage(let text, _, let from) = entry.kind { return (text, from) }
            return nil
        }
    }

    private func asks(_ core: DaemonCore, _ id: UUID) async throws -> Int {
        try await prompts(core, id).count { $0.1 == .app }
    }

    @Test func aSilentTurnIsDoneWithItsFirstSentenceAndNothingIsAsked() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: Self.saying("Renamed the 14 call sites. ", "Tests pass."))
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work,
                                            prompt: "Rename the old helper everywhere it is used please"))

        await settled(core, id, "the turn ended")
        try await Task.sleep(for: .milliseconds(200))
        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .done)
        #expect(agent.report?.message == "Renamed the 14 call sites.")
        #expect(agent.title == "Rename the old helper everywhere it is used please")
        #expect(agent.suggestedPrompts.isEmpty)
        #expect(agent.endingIsUnaccountedFor == false)
        #expect(agent.group(wantsEyes: false) == .finished)
        #expect(try await asks(core, id) == 0)
    }

    @Test func closingWordsThatAskAreWaitingOnAnAnswer() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: Self.saying("I found two ways to do it.\n\n",
                                                        "Shall I keep the old name as an alias?"))
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        await settled(core, id, "the turn ended")
        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .needsAnswer)
        #expect(agent.report?.message == "Shall I keep the old name as an alias?")
        #expect(try await asks(core, id) == 0)
    }

    @Test func aTurnThatSaidNothingAtAllIsStillDone() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        await settled(core, id, "the turn ended")
        #expect(await core.agent(id)?.report?.outcome == .done)
        #expect(await core.agent(id)?.report?.message == DerivedEnding.silentDone)
        #expect(try await asks(core, id) == 0)
    }

    /// Older conversations and workflows still call it, and what they said is kept.
    @Test func finishTurnWinsOverWhatWouldBeDerived() async throws {
        let (locations, work) = try temporary()
        let turn = TurnGate()
        var script = Self.saying("Something else entirely.")
        script.gate = turn
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

        let token = await eventuallySome("the runtime was handed its token") {
            let minted = MintedMCPToken.from(sessionParams: await launcher.lastAgent?.newSessionParams)
            return minted.isEmpty ? nil : minted
        } ?? ""
        _ = try await core.finishTurn(.init(token: token, outcome: "partly_done",
                                            message: "Five of six.", prompts: [], title: "Six things"))
        turn.open()
        await settled(core, id, "the turn ended")

        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .partlyDone)
        #expect(agent.report?.message == "Five of six.")
        #expect(agent.title == "Six things")
        #expect(try await asks(core, id) == 0)
    }

    /// A turn that ended short keeps its own wording, and nothing is made up for it.
    @Test func aTurnThatEndedShortIsLeftToItsOwnWording() async throws {
        for stop in ["cancelled", "max_tokens", "refusal"] {
            let (locations, work) = try temporary()
            var script = Self.saying("Half way.")
            script.stopReason = stop
            let core = try core(FakeLauncher(script: script), locations: locations)
            let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))

            await eventually("the \(stop) turn ended") {
                guard let agent = await core.agent(id) else { return false }
                let turning = await core.turnTasks[id] != nil
                return !agent.state.hasTurnInFlight && agent.endedReason != nil && !turning
            }
            let agent = try #require(await core.agent(id))
            #expect(agent.report == nil, "\(stop) was given a report")
            #expect(agent.endedReason?.summary != nil)
            #expect(try await asks(core, id) == 0, "\(stop) was asked about")
        }
    }

    /// The person's next prompt clears the last account, and its turn gets its own.
    @Test func eachTurnIsAccountedForAfresh() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: Self.saying("First done."))
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "one"))
        await settled(core, id, "the first turn ended")
        #expect(await core.agent(id)?.report?.message == "First done.")

        try await core.prompt(.init(agentID: id, text: "two"))
        await settled(core, id, "the second turn ended")
        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == .done)
        // Named once, from the first prompt, and left.
        #expect(agent.title == "one")
        #expect(try await prompts(core, id).map(\.1) == [.person, .person])
    }
}
