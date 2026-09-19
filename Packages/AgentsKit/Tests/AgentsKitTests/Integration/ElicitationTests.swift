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
         "schema": ["title": "Which branch?",
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
                                  ["schema": ["properties": ["mystery": ["type": "hologram"]]]])]
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
