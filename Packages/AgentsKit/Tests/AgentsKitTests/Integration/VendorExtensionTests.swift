import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Methods a runtime invented, answered by name or by the capability it advertised
/// (`.agents/research/acp-vendor-extensions.md`). Shapes are Cursor 2026.09.10's and
/// the Claude adapter 0.81.2's, read in their source.
@Suite("Vendor extensions", .timeLimit(.minutes(1)))
struct VendorExtensionTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsVendorExtensionTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: cursor/update_todos

    private func todos(_ items: [(String, String, String)], merge: Bool) -> JSONValue {
        ["toolCallId": "tc1",
         "todos": .array(items.map { ["id": .string($0.0), "content": .string($0.1), "status": .string($0.2)] }),
         "merge": .bool(merge)]
    }

    @Test func cursorTodosBecomeThePlanAndMergeById() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [
            (ACP.ExtensionMethod.updateTodos, todos([("1", "Read the code", "in_progress"),
                                                     ("2", "Write the test", "pending"),
                                                     ("3", "Ship it", "pending")], merge: false)),
            (ACP.ExtensionMethod.updateTodos, todos([("1", "Read the code", "completed"),
                                                     ("3", "Ship it", "cancelled"),
                                                     ("4", "Tell Alex", "pending")], merge: true)),
        ]
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await eventually("the turn ran on to its end") { await core.agent(id)?.state == .finished }

        let plan = await core.agent(id)?.plans.last
        #expect(plan?.entries.map(\.content) == ["Read the code", "Write the test", "Tell Alex"],
                "merged by id, the cancelled one left out, the new one added at the end")
        #expect(plan?.entries.map(\.status) == [.completed, .pending, .pending])

        let answers = await launcher.lastAgent?.answers(to: ACP.ExtensionMethod.updateTodos) ?? []
        #expect(answers.count == 2)
        for answer in answers {
            guard case .success(let result) = answer else {
                Issue.record("update_todos was declined")
                continue
            }
            #expect(result == .object([:]))
        }
    }

    @Test func cursorTodosWithoutMergeReplaceTheList() {
        var list = TodoList()
        _ = list.apply(todos([("1", "One", "pending"), ("2", "Two", "pending")], merge: false))
        _ = list.apply(todos([("9", "Nine", "in_progress")], merge: false))
        #expect(list.plan.entries.map(\.content) == ["Nine"])
        #expect(list.plan.entries.first?.status == .inProgress)
        #expect(list.plan.planID == nil, "the session's one plan, as `plan` updates are")
    }

    // MARK: cursor/ask_question

    private var questions: JSONValue {
        ["toolCallId": "tc2",
         "title": "Before I start",
         "questions": [
            ["id": "lang", "prompt": "Which language?",
             "options": [["id": "swift", "label": "Swift"], ["id": "go", "label": "Go"]],
             "allowMultiple": false],
            ["id": "extras", "prompt": "Also do", "allowMultiple": true,
             "options": [["id": "tests", "label": "Tests"], ["id": "docs", "label": "Docs"],
                         ["id": "ci", "label": "CI"]]],
         ]]
    }

    private func askedAndAnswered(_ answer: DaemonAPI.AnswerElicitationRequest.Action,
                                  content: [String: JSONValue] = [:],
                                  check: (ElicitationRequest) -> Void = { _ in }) async throws -> JSONValue? {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ExtensionMethod.askQuestion, questions)]
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        await eventually("the questions reached the daemon") {
            await core.pendingElicitations().isEmpty == false
        }
        guard let request = await core.pendingElicitations().first else { return nil }
        check(request)
        try await core.answerElicitation(.init(requestID: request.id, action: answer, content: content))
        let reply = await eventuallySome("Cursor was answered") {
            await launcher.lastAgent?.answer(to: ACP.ExtensionMethod.askQuestion)
        }
        guard case .success(let result)? = reply else { return nil }
        return result
    }

    @Test func cursorQuestionsAreAFormAndAnsweredInCursorsShape() async throws {
        let result = try await askedAndAnswered(.accept,
                                                content: ["lang": "swift", "extras": ["tests", "ci"]]) { request in
            #expect(request.title == "Before I start")
            guard case .form(let schema) = request.mode else {
                Issue.record("expected a form")
                return
            }
            #expect(schema.properties.map(\.name) == ["lang", "extras"], "in Cursor's order, keyed by its ids")
            #expect(schema.properties.map(\.title) == ["Which language?", "Also do"])
            guard case .string(_, _, _, let one) = schema.properties[0].kind,
                  case .multiSelect(let many, _, _) = schema.properties[1].kind else {
                Issue.record("allowMultiple was not a multi-select")
                return
            }
            #expect(one?.map(\.title) == ["Swift", "Go"])
            #expect(many.map(\.value) == ["tests", "docs", "ci"])
        }
        #expect(result?["outcome"]?["outcome"]?.stringValue == "answered")
        let answers = result?["outcome"]?["answers"]?.arrayValue ?? []
        let byQuestion = Dictionary(uniqueKeysWithValues: answers.compactMap { answer -> (String, [String])? in
            guard let id = answer["questionId"]?.stringValue else { return nil }
            return (id, answer["selectedOptionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        })
        #expect(byQuestion == ["lang": ["swift"], "extras": ["tests", "ci"]])
    }

    @Test func decliningCursorQuestionsIsASkip() async throws {
        let result = try await askedAndAnswered(.decline)
        #expect(result?["outcome"]?["outcome"]?.stringValue == "skipped")
    }

    @Test func aCursorQuestionWithNoOptionsIsLeftToCursorsFallback() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ExtensionMethod.askQuestion,
                                  ["questions": [["id": "q", "prompt": "Anything?", "options": []]]])]
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        let reply = await eventuallySome("Cursor was answered") {
            await launcher.lastAgent?.answer(to: ACP.ExtensionMethod.askQuestion)
        }
        guard case .failure(let error)? = reply else {
            Issue.record("a question we cannot draw was answered")
            return
        }
        #expect(error.code == -32601)
        #expect(await core.pendingElicitations().isEmpty)
    }

    // MARK: _auth/status_update

    private let claudeMax: JSONValue = [
        "authStatus": ["kind": "account", "label": "Claude Max",
                       "account": ["plan": "max", "email": "someone@example.com", "organization": "Acme"]],
    ]

    @Test func anAdvertisedAuthStatusSaysWhoIsSignedInAndNeverKeepsTheEmail() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.agentCapabilities = ["_meta": ["authStatus": [:]]]
        script.extensionNotifications = [(ACP.ExtensionMethod.authStatusUpdate, claudeMax)]
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the account was noted") {
            await core.account(for: "claude").signedInAs != nil
        }
        let account = await core.account(for: "claude")
        #expect(account.signedInAs == AuthStatus(kind: "account", label: "Claude Max"))
        #expect(account.state == .ready)
        // What goes to every window and the phone.
        let wire = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
        #expect(!wire.contains("someone@example.com"))
        #expect(!wire.contains("Acme"))
    }

    @Test func anAdvertisedSignOutIsASignInNeeded() async throws {
        let (locations, work) = try temporary()
        let gate = TurnGate()
        var script = FakeACPAgent.Script()
        script.agentCapabilities = ["_meta": ["authStatus": [:]]]
        script.extensionNotifications = [(ACP.ExtensionMethod.authStatusUpdate,
                                          ["authStatus": ["kind": "none", "label": "Not logged in"]])]
        // Held, because a turn that then works is the better proof and puts it back to ready.
        script.gate = gate
        let core = try core(FakeLauncher(script: script, capabilities: .app), locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("signing out elsewhere was heard") {
            await core.account(for: "claude").state == .needsSignIn
        }
        #expect(await core.account(for: "claude").signedInAs?.isSignedOut == true)
        gate.open()
    }

    @Test func anAuthStatusFromARuntimeThatNeverAdvertisedItIsNotRead() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.extensionNotifications = [(ACP.ExtensionMethod.authStatusUpdate, claudeMax)]
        let core = try core(FakeLauncher(script: script, capabilities: .app), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the turn ran on to its end") { await core.agent(id)?.state == .finished }
        // An absence, so time passing is the assertion: the events behind the turn's end
        // have had their chance.
        try await Task.sleep(for: .milliseconds(150))
        #expect(await core.account(for: "claude").signedInAs == nil)
    }
}
