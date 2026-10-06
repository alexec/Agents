import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `ask_form`: the app's own question tool, held as an elicitation until answered.
@Suite("ask_form", .timeLimit(.minutes(1)))
struct AskFormTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsAskFormTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test func anAskFormIsHeldAndAnsweredInWords() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(script: .init(), capabilities: .app), locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await core.bindAppToken("ask-token", to: id)

        let asked = Task {
            try await core.askForm(.init(
                token: "ask-token",
                title: "Quick check",
                questions: [.init(id: "drink", prompt: "Drink?",
                                  options: [.init(id: "tea", label: "Tea"),
                                            .init(id: "coffee", label: "Coffee")])]))
        }
        await eventually("the form is held") { await !core.pendingElicitations().isEmpty }
        let form = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: form.id, action: .accept,
                                               content: ["drink": .string("tea")]))
        let note = try await asked.value
        #expect(note.contains("Tea") || note.contains("tea"))
        #expect(note.contains("Drink?"))
        #expect(await core.pendingElicitations().isEmpty)
    }

    @Test func skippingAnAskFormTellsTheAgent() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(script: .init(), capabilities: .app), locations: locations)
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await core.bindAppToken("skip-token", to: id)

        let asked = Task {
            try await core.askForm(.init(
                token: "skip-token",
                questions: [.init(id: "q", prompt: "Anything?")]))
        }
        await eventually("the form is held") { await !core.pendingElicitations().isEmpty }
        let form = try #require(await core.pendingElicitations().first)
        try await core.answerElicitation(.init(requestID: form.id, action: .decline))
        #expect(try await asked.value == "They skipped the questions.")
    }

    @Test func answeringAQuestionAfterTheTurnStartsAContextualTurn() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(100)
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await eventually("the first turn started") { await core.turnTasks[id] != nil }

        let request = ElicitationRequest(
            agentID: id,
            message: "Which branch?",
            mode: .form(ElicitationSchema(properties: [
                .init(name: "branch", title: "Branch name", isRequired: true,
                      kind: .string(format: nil, minLength: nil, maxLength: nil, choices: nil))
            ])))
        await core.holdElicitation(request, agentID: id)
        await eventually("the first turn ended") { await core.turnTasks[id] == nil }
        try await core.answerElicitation(.init(requestID: request.id, action: .accept,
                                               content: ["branch": .string("main")]))

        await eventually("the answer started another turn") { launcher.launchCount == 2 }
        let delivered = await eventuallySome("the queued answer reached the runtime") {
            if let blocks = await launcher.lastAgent?.promptContent?.arrayValue {
                return blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            }
            return nil
        }
        #expect(delivered?.contains("Which branch?") == true)
        #expect(delivered?.contains("Branch name: main") == true)
    }
}
