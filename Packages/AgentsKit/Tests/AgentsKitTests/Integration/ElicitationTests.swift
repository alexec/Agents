import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Answering an agent's form", .timeLimit(.minutes(1)))
struct ElicitationTests {
    private let serving = ACP.ClientCapabilities(elicitationForm: true, elicitationURL: true)

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsElicitationTests-\(UUID().uuidString)", isDirectory: true)
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

    private var aForm: JSONValue {
        ["elicitationId": "e1",
         "mode": "form",
         "message": "Which branch?",
         "requestedSchema": ["title": "Which branch?",
                             "properties": ["branch": ["type": "string", "title": "Branch"]],
                             "required": ["branch"]]]
    }

    @Test func aFormIsHeldWithNobodyWatchingAndAnsweredLater() async throws {
        // The same machinery as a permission question, which is the point: the daemon
        // holds it, and any window can answer it whenever it opens.
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation, aForm)]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        // The agent's state is one of the assertions below, and it is set a beat after
        // the form is registered, so waiting on the form alone would read it too early.
        await eventually("the agent is waiting on its form") {
            await core.agent(id)?.state == .waitingOnUser
        }

        let waiting = await core.pendingElicitations()
        #expect(waiting.count == 1)
        #expect(waiting.first?.title == "Which branch?")
        #expect(await core.agent(id)?.state == .waitingOnUser)

        guard let request = waiting.first else { return }
        try await core.answerElicitation(.init(requestID: request.id, action: .accept,
                                               content: ["branch": "main"]))
        let answer = await eventuallySome("the agent was answered") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
        }
        guard case .success(let result)? = answer else {
            Issue.record("the agent was not answered")
            return
        }
        #expect(result["action"]?.stringValue == "accept")
        #expect(result["content"]?["branch"]?.stringValue == "main")
        #expect(await core.pendingElicitations().isEmpty)
    }

    /// Exactly what the Claude adapter sends when the model calls AskUserQuestion:
    /// the question in `message`, a titled `oneOf` and a titled `items.anyOf`, an
    /// "Other" box beside each, and nothing required. Every one of those was read
    /// wrongly, so the form was declined unseen and the model was told nobody answered.
    @Test func anAskUserQuestionFormIsDrawnAndAnswered() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation,
            ["mode": "form",
             "sessionId": "s1",
             "toolCallId": "toolu_1",
             "message": "Which way do you want it?",
             "requestedSchema": [
                "type": "object",
                "properties": [
                    "question_0": ["type": "string",
                                   "title": "Thinking blocks",
                                   "oneOf": [["const": "Keep them", "title": "Keep them",
                                              "description": "Nothing to build"],
                                             ["const": "Move them", "title": "Move them",
                                              "description": "Simpler state"]]],
                    "question_0_custom": ["type": "string", "title": "Other"],
                    "question_1": ["type": "array",
                                   "title": "Also do",
                                   "items": ["anyOf": [["const": "Update CLAUDE.md", "title": "Update CLAUDE.md"],
                                                       ["const": "Add a resume test", "title": "Add a resume test"]]]],
                    "question_1_custom": ["type": "string", "title": "Other"],
                ]]])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the form reached the daemon") {
            await core.pendingElicitations().isEmpty == false
        }

        guard let request = await core.pendingElicitations().first else {
            Issue.record("the question never reached anybody")
            return
        }
        #expect(request.message == "Which way do you want it?")
        guard case .form(let schema) = request.mode else {
            Issue.record("expected a form")
            return
        }
        #expect(schema.properties.count == 4)
        guard case .string(_, _, _, let picks) = schema.properties[0].kind,
              case .multiSelect(let alsoDo, _, _) = schema.properties[2].kind else {
            Issue.record("the choices were not read as choices")
            return
        }
        #expect(picks?.map(\.value) == ["Keep them", "Move them"])
        #expect(picks?.first?.description == "Nothing to build")
        #expect(alsoDo.map(\.value) == ["Update CLAUDE.md", "Add a resume test"])

        try await core.answerElicitation(.init(requestID: request.id, action: .accept,
                                               content: ["question_0": "Keep them",
                                                         "question_1": .array(["Update CLAUDE.md"])]))
        let answer = await eventuallySome("the agent was answered") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
        }
        guard case .success(let result)? = answer else {
            Issue.record("the agent was not answered")
            return
        }
        #expect(result["action"]?.stringValue == "accept")
        #expect(result["content"]?["question_0"]?.stringValue == "Keep them")
        #expect(result["content"]?["question_1"]?.arrayValue?.first?.stringValue == "Update CLAUDE.md")
    }

    @Test func anAnswerThatDoesNotFitIsNotSent() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation, aForm)]
        let core = try core(FakeLauncher(script: script, capabilities: serving), locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the form reached the daemon") {
            await core.pendingElicitations().isEmpty == false
        }
        guard let request = await core.pendingElicitations().first else {
            Issue.record("expected a form")
            return
        }
        await #expect(throws: JSONRPCError.self) {
            // Nothing for a required property: the agent asked for something specific.
            try await core.answerElicitation(.init(requestID: request.id, action: .accept, content: [:]))
        }
        #expect(await core.pendingElicitations().count == 1, "still waiting, not lost")
    }

    @Test func decliningIsAnAnswerAndTheAgentCarriesOn() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation, aForm)]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the form reached the daemon") {
            await core.pendingElicitations().isEmpty == false
        }
        guard let request = await core.pendingElicitations().first else {
            Issue.record("expected a form")
            return
        }
        try await core.answerElicitation(.init(requestID: request.id, action: .decline))
        let answer = await eventuallySome("the agent was answered") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
        }
        await eventually("the turn ran on to its end") { await core.agent(id)?.state == .finished }
        guard case .success(let result)? = answer else {
            Issue.record("the agent was not answered")
            return
        }
        #expect(result["action"]?.stringValue == "decline")
        #expect(await core.agent(id)?.state == .finished, "declining is not a failure")
    }

    @Test func aFormWeCannotDrawIsDeclinedRatherThanHalfAnswered() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation,
                                  ["mode": "form",
                                   "message": "Pick one",
                                   "requestedSchema": ["properties": ["mystery": ["type": "hologram"]]]])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        let answer = await eventuallySome("the agent was answered") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
        }

        #expect(await core.pendingElicitations().isEmpty, "nobody is asked something we cannot draw")
        guard case .success(let result)? = answer else {
            Issue.record("the agent was not answered")
            return
        }
        #expect(result["action"]?.stringValue == "decline")
    }

    @Test func stoppingAnAgentTakesItsFormDownWithIt() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation, aForm)]
        let core = try core(FakeLauncher(script: script, capabilities: serving), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the form reached the daemon") {
            await core.pendingElicitations().isEmpty == false
        }
        #expect(await core.pendingElicitations().count == 1)

        try await core.stop(id)
        await eventually("the form went with the agent") {
            await core.pendingElicitations().isEmpty
        }
        #expect(await core.pendingElicitations().isEmpty)
    }

    /// The form is taken down by the runtime rather than answered here — the same
    /// question was put somewhere else, or the model changed its mind — and the agent
    /// has to come back out of "Needs attention" with it. A withdrawn form that left
    /// the state behind is an agent sitting under that heading with nothing on the
    /// page to answer, and no way out of `waitingOnUser` except stopping it.
    @Test func aWithdrawnFormTakesTheAgentOutOfWaiting() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation, aForm)]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the agent is waiting on its form") {
            await core.agent(id)?.state == .waitingOnUser
        }

        #expect(launcher.launchCount == 1, "launches: \(launcher.launchCount)")
        #expect(await launcher.lastAgent?.received.contains(ACP.Method.prompt) == true,
                "the last agent is not the one holding the form")
        await launcher.lastAgent?.emit(FakeACPAgent.chunk("still listening"))
        await eventually("an ordinary update still arrives while a form is pending") {
            let page = try? await core.transcript(.init(agentID: id, before: nil, limit: 200))
            return page?.entries.contains { "\($0.kind)".contains("still listening") } == true
        }
        await launcher.lastAgent?.emitNotification(ACP.ClientMethod.completeElicitation,
                                                   ["elicitationId": "e1"])
        let answer = await eventuallySome("the runtime heard the cancel") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
        }
        #expect(answer != nil)
        await eventually("the form came down") {
            await core.pendingElicitations().isEmpty
        }
        // The fake ends its turn the moment it hears the cancel, so by the time the
        // form is seen to be gone the agent may already be finished. What must be true
        // is that it passed through `running` on the way — the step a withdrawal used
        // to skip — rather than going from waiting straight to the end.
        let states = try await core.transcript(.init(agentID: id, before: nil, limit: 200)).entries
            .compactMap { entry -> AgentState? in
                if case .stateChanged(let state, _) = entry.kind { return state }
                return nil
            }
        let lastWaiting = states.lastIndex(of: .waitingOnUser) ?? -1
        let lastRunning = states.lastIndex(of: .running) ?? -1
        #expect(lastRunning > lastWaiting, "states: \(states)")
        #expect(states.last != .waitingOnUser, "states: \(states)")
        #expect(await core.agent(id)?.state != .waitingOnUser)
        #expect(await core.agent(id)?.group != .needsAttention)
    }

    @Test func nothingIsAskedWhenWeDidNotSayWeTakeForms() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation, aForm)]
        let launcher = FakeLauncher(script: script, capabilities: .none)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        let answer = await eventuallySome("the agent was answered") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
        }
        guard case .failure(let error)? = answer else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.isMethodNotFound)
    }
}
