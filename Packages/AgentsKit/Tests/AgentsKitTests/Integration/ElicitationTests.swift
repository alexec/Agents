import Foundation
import Testing
@testable import AgentsKit

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
        try await Task.sleep(for: .milliseconds(300))

        let waiting = await core.pendingElicitations()
        #expect(waiting.count == 1)
        #expect(waiting.first?.title == "Which branch?")
        #expect(await core.agent(id)?.state == .waitingOnUser)

        guard let request = waiting.first else { return }
        try await core.answerElicitation(.init(requestID: request.id, action: .accept,
                                               content: ["branch": "main"]))
        try await Task.sleep(for: .milliseconds(300))

        let answer = await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
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
        try await Task.sleep(for: .milliseconds(300))

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
        try await Task.sleep(for: .milliseconds(300))

        let answer = await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
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
        try await Task.sleep(for: .milliseconds(300))
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
        try await Task.sleep(for: .milliseconds(300))
        guard let request = await core.pendingElicitations().first else {
            Issue.record("expected a form")
            return
        }
        try await core.answerElicitation(.init(requestID: request.id, action: .decline))
        try await Task.sleep(for: .milliseconds(300))

        let answer = await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
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
        try await Task.sleep(for: .milliseconds(300))

        #expect(await core.pendingElicitations().isEmpty, "nobody is asked something we cannot draw")
        let answer = await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
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
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.pendingElicitations().count == 1)

        try await core.stop(id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.pendingElicitations().isEmpty)
    }

    @Test func nothingIsAskedWhenWeDidNotSayWeTakeForms() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation, aForm)]
        let launcher = FakeLauncher(script: script, capabilities: .none)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        try await Task.sleep(for: .milliseconds(300))

        let answer = await launcher.lastAgent?.answer(to: ACP.ClientMethod.createElicitation)
        guard case .failure(let error)? = answer else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.isMethodNotFound)
    }
}
