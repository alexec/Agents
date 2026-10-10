import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The MCP server we hand to every agent.
///
/// It is four methods over a pipe, and a runtime that cannot complete the handshake
/// never sees the tool at all, so these are about the shape of the answers as much as
/// about what a call does.
@Suite("The tools we serve", .timeLimit(.minutes(1)))
struct AppServiceTests {
    /// A service on one end of a pipe and a plain JSON-RPC client on the other, which
    /// is what a runtime is here.
    private func pair(showFile: @escaping AppService.FileSink = { _ in .refused("not expected") },
                      askForm: @escaping AppService.AskFormSink = { _, _ in .refused("not expected") })
        async -> (client: JSONRPCConnection, service: AppService) {
        let (mine, theirs) = PairedTransport.pair()
        let service = AppService(transport: theirs, showFile: showFile, askForm: askForm)
        let client = JSONRPCConnection(transport: mine)
        await client.start()
        return (client, service)
    }

    @Test func itAnswersTheHandshakeWithTheVersionTheClientAsked() async throws {
        let (client, service) = await pair()
        let result = try await client.call("initialize", ["protocolVersion": "2025-03-26"])
        #expect(result["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(result["serverInfo"]?["name"]?.stringValue == "agents")
        // The tools capability is what makes a client ask for the list at all.
        #expect(result["capabilities"]?["tools"] != nil)
        await service.close()
    }

    @Test func aClientThatNamesNoVersionGetsOurs() async throws {
        let (client, service) = await pair()
        let result = try await client.call("initialize", .object([:]))
        #expect(result["protocolVersion"]?.stringValue == AppService.protocolVersion)
        await service.close()
    }

    @Test func everyToolIsListedWithASchemaTheAgentCanFill() async throws {
        let (client, service) = await pair()
        let result = try await client.call("tools/list", .object([:]))
        let tools = result["tools"]?.arrayValue ?? []
        // No tool ends a turn: the app works out how each one ended.
        // The four agent tools (028 + park) sit after the workflow tool, for an agent
        // that may use them — which is the default. The three lease tools (036) follow
        // them, for every agent, then the three event tools (042). Labels and moving
        // (053) have tools of their own since #481. The two session tools (065) and message_agent (#560) sit after the agent tools, for every
        // agent. The pin tools (#159, #180) come last, for every agent.
        #expect(tools.compactMap { $0["name"]?.stringValue }
            == [AppService.showFileToolName,
                AppService.workflowToolName, AppService.askFormToolName,
                AppService.startAgentToolName, AppService.stopAgentToolName,
                AppService.parkAgentToolName, AppService.archiveAgentToolName,
                AppService.listMyAgentsToolName,
                AppService.setSessionLabelsToolName, AppService.moveWorktreeToolName,
                AppService.listSessionsToolName, AppService.readSessionToolName,
                AppService.messageAgentToolName,
                AppService.leaseResourceToolName, AppService.releaseResourceToolName,
                AppService.listResourcesToolName,
                AppService.waitForEventToolName, AppService.cancelWaitToolName,
                AppService.publishEventToolName,
                AppService.pinPageToolName, AppService.unpinPageToolName, AppService.movePinToolName,
                AppService.pinSessionToolName])

        try #require(tools.count > 2)
        let showFile = tools[0]["inputSchema"]
        #expect(showFile?["properties"]?["path"] != nil)
        #expect(showFile?["properties"]?["line"] != nil)
        // The line is the optional half: an agent that only knows the file still has
        // a call it can make.
        #expect(showFile?["required"]?.arrayValue?.compactMap { $0.stringValue } == ["path"])
        // And nothing else. 022 made a Markdown file a live page and changed nothing
        // the agent is given but the description: a line lands on the passage that
        // holds it, so there is no `heading`, and the contract in
        // specs/022-live-artifacts/contracts/show-file-tool.md says the schema is not
        // to grow. An argument added here is a contract change, and this is what
        // says so.
        #expect(showFile?["properties"]?.objectValue?.keys.sorted() == ["line", "path"])

        let workflows = tools[1]["inputSchema"]
        #expect(workflows?["properties"]?["action"]?["enum"]?.arrayValue?
            .compactMap { $0.stringValue } == ["list", "read", "write", "remove", "enable", "disable"])
        // Only the action is required: `list` needs nothing else, which is the call an
        // agent makes first.
        #expect(workflows?["required"]?.arrayValue?.compactMap { $0.stringValue } == ["action"])

        await service.close()
    }

    @Test func aWorkflowCallWithNoUsableActionIsToldRatherThanGuessedAt() async throws {
        let (client, service) = await pair()
        let result = try await client.call("tools/call", [
            "name": .string(AppService.workflowToolName),
            "arguments": ["action": "schedule"],
        ])
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?
            .contains("list, read, write") == true)
        await service.close()
    }

    @Test func someOtherToolIsNotOurs() async throws {
        let (client, service) = await pair()
        await #expect(throws: JSONRPCError.self) {
            _ = try await client.call("tools/call", ["name": "rm_rf", "arguments": .object([:])])
        }
        await service.close()
    }

    // MARK: Showing a file

    @Test func aFileAndALineReachTheSinkAndTheAgentIsToldWhatHappened() async throws {
        let box = FileBox()
        let (client, service) = await pair(showFile: { file in
            await box.record(file)
            return .shown("README.md is open at line 12.")
        })
        let result = try await client.call("tools/call", [
            "name": .string(AppService.showFileToolName),
            "arguments": ["path": "/tmp/project/README.md", "line": 12],
        ])
        #expect(await box.file?.path == "/tmp/project/README.md")
        #expect(await box.file?.line == 12)
        #expect(result["isError"]?.boolValue == false)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "README.md is open at line 12.")
        await service.close()
    }

    /// The one thing 022 gives the agent is a sentence. The description is what an
    /// agent reads when it reaches for the tool, and these are the words that make a
    /// Markdown file a page it shows once and then writes on.
    @Test func theShowFileDescriptionSaysAMarkdownFileIsALivePage() async throws {
        let (client, service) = await pair()
        let result = try await client.call("tools/list", .object([:]))
        let description = result["tools"]?.arrayValue?[0]["description"]?.stringValue ?? ""
        #expect(description.contains("opens as a page"))
        #expect(description.contains("follows your edits"))
        #expect(description.contains("show it once"))
        #expect(description.contains("does not have to exist yet"))
        await service.close()
    }

    @Test func aPrefixedShowFileIsStillOurTool() async throws {
        let box = FileBox()
        let (client, service) = await pair(showFile: { file in
            await box.record(file)
            return .shown("ok")
        })
        _ = try await client.call("tools/call", [
            "name": "mcp__agents__show_file",
            "arguments": ["path": "/tmp/project/a.swift"],
        ])
        #expect(await box.file?.path == "/tmp/project/a.swift")
        // No line named is the top of the file, not line zero.
        #expect(await box.file?.line == nil)
        await service.close()
    }

    // MARK: Asking a form

    @Test func anAskFormReachesTheSinkAndTheAgentIsToldWhatHappened() async throws {
        let box = AskFormBox()
        let (client, service) = await pair(askForm: { title, questions in
            await box.record(title, questions)
            return .shown("They answered:\n- Drink?: tea")
        })
        let result = try await client.call("tools/call", [
            "name": .string(AppService.askFormToolName),
            "arguments": [
                "title": "Quick check",
                "questions": [
                    ["id": "drink", "prompt": "Drink?",
                     "options": [["id": "tea", "label": "Tea"], ["id": "coffee", "label": "Coffee"]]],
                ],
            ],
        ])
        #expect(await box.title == "Quick check")
        #expect(await box.questions.map(\.id) == ["drink"])
        #expect(await box.questions.first?.options?.map(\.id) == ["tea", "coffee"])
        #expect(result["isError"]?.boolValue == false)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?
            .contains("tea") == true)
        await service.close()
    }

    @Test func anAskFormWithNoQuestionsIsToldRatherThanGuessedAt() async throws {
        let (client, service) = await pair(askForm: { _, _ in
            .shown("should not happen")
        })
        let result = try await client.call("tools/call", [
            "name": .string(AppService.askFormToolName),
            "arguments": ["questions": .array([])],
        ])
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?
            .contains("at least one question") == true)
        await service.close()
    }

    @Test func aPrefixedAskFormIsStillOurTool() async throws {
        let box = AskFormBox()
        let (client, service) = await pair(askForm: { title, questions in
            await box.record(title, questions)
            return .shown("ok")
        })
        _ = try await client.call("tools/call", [
            "name": "mcp__agents__ask_form",
            "arguments": ["questions": [["id": "q", "prompt": "Anything?"]]],
        ])
        #expect(await box.questions.map(\.prompt) == ["Anything?"])
        #expect(await box.questions.first?.options == nil)
        await service.close()
    }

    private actor AskFormBox {
        var title: String?
        var questions: [DaemonAPI.AskFormRequest.Question] = []
        func record(_ title: String?, _ questions: [DaemonAPI.AskFormRequest.Question]) {
            self.title = title
            self.questions = questions
        }
    }

    /// A relative path is the one mistake an agent will actually make, because that is
    /// what it types in a terminal all day. It is refused here rather than resolved
    /// against a working directory this process does not have.
    @Test func aRelativePathIsRefusedBeforeItReachesTheSink() async throws {
        let (client, service) = await pair(showFile: { _ in .shown("should not happen") })
        let result = try await client.call("tools/call", [
            "name": .string(AppService.showFileToolName),
            "arguments": ["path": "src/main.swift"],
        ])
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("absolute") == true)
        await service.close()
    }

    @Test func aLineThatIsNotAPlaceIsDroppedAndTheFileStillOpens() async throws {
        let box = FileBox()
        let (client, service) = await pair(showFile: { file in
            await box.record(file)
            return .shown("ok")
        })
        _ = try await client.call("tools/call", [
            "name": .string(AppService.showFileToolName),
            "arguments": ["path": "/tmp/project/a.swift", "line": 0],
        ])
        #expect(await box.file?.path == "/tmp/project/a.swift")
        #expect(await box.file?.line == nil)
        await service.close()
    }

    private actor FileBox {
        private(set) var file: ShownFile?
        func record(_ file: ShownFile) { self.file = file }
    }

    // MARK: Ending the turn in one call

    /// The two older names for the halves of `finish_turn` were retired (023 R5): not
    /// listed, and a call to either, prefixed or not, is no tool of ours.
    @Test func theRetiredNamesAreNeitherListedNorAnswered() async throws {
        let (client, service) = await pair()
        let listed = try await client.call("tools/list", .object([:]))["tools"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue } ?? []
        for name in AppTool.retiredEndOfTurn {
            #expect(!listed.contains(name))
            for called in [name, "mcp__agents__\(name)"] {
                await #expect(throws: JSONRPCError.self) {
                    _ = try await client.call("tools/call", [
                        "name": .string(called),
                        "arguments": ["outcome": "done", "message": "All done.",
                                      "prompts": .array([["label": "One", "prompt": "Do one"]])],
                    ])
                }
            }
        }
        await service.close()
    }

    /// Gone altogether: no tool ends a turn. Not listed, and a call to it, prefixed or
    /// not, is no tool of ours.
    @Test func finishTurnIsNeitherListedNorAnswered() async throws {
        let (client, service) = await pair()
        let listed = try await client.call("tools/list", .object([:]))["tools"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue } ?? []
        #expect(!listed.contains(AppTool.finishTurn))
        for called in [AppTool.finishTurn, "mcp__agents__\(AppTool.finishTurn)"] {
            await #expect(throws: JSONRPCError.self) {
                _ = try await client.call("tools/call", [
                    "name": .string(called), "arguments": ["outcome": "done", "message": "All done."],
                ])
            }
        }
        #expect(AppService.parkAgentTool["inputSchema"]?["required"] == nil, "no id is yourself")
        await service.close()
    }

    @Test func aRefusalIsAToolErrorRatherThanAProtocolError() async throws {
        let (client, service) = await pair(showFile: { _ in
            .refused("That conversation is closed.")
        })
        let result = try await client.call("tools/call", [
            "name": .string(AppService.showFileToolName),
            "arguments": ["path": "/tmp/a.md"],
        ])
        // Not a JSON-RPC failure: the agent is meant to read this and carry on.
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "That conversation is closed.")
        await service.close()
    }

    /// The app tells its own tools apart by the end of their names (a runtime may
    /// prefix them), so no tool's name may end with another's. 036's release_resource
    /// once ended with lease_resource, and every release became an extension.
    /// The one pair that does (#159): unpin_page ends with pin_page, so it is matched first,
    /// under every runtime's spelling. A real agent's unpin was taken for a pin before this.
    @Test func unpinPageIsNeverTakenForPinPage() throws {
        for prefix in ["", "mcp__agents__", "agents_", "agents__"] {
            #expect(try AppService.pinCall(named: prefix + AppTool.unpinPage, ["path": "a.md"])?.get()
                    == .unpin(arguments: ["path": "a.md"]))
            #expect(try AppService.pinCall(named: prefix + AppTool.pinPage, ["path": "a.md"])?.get()
                    == .pin(arguments: ["path": "a.md"]))
        }
    }

    @Test func noToolNameEndsWithAnother() {
        let names = [AppTool.showFile, AppTool.manageWorkflows, AppTool.askForm,
                     AppTool.startAgent, AppTool.stopAgent, AppTool.parkAgent, AppTool.archiveAgent,
                     AppTool.listMyAgents,
                     AppTool.waitForEvent, AppTool.cancelWait, AppTool.publishEvent,
                     AppTool.listResources]
        for name in names {
            for other in names + [AppTool.leaseResource] where other != name {
                #expect(!name.hasSuffix(other), "\(name) ends with \(other)")
            }
        }
    }

    /// The workflow tool and the wait tool describe the same catalogue in the same words
    /// (042 FR-024).
    @Test func theWorkflowToolListsTheSameEventsTheWaitToolDoes() {
        let description = AppService.workflowTool["description"]?.stringValue ?? ""
        #expect(description.hasSuffix(EventList.text()))
    }

    // MARK: 073: where takes a list, and drops nothing

    @Test func aWaitsWhereTakesAListAndRefusesWhatIsNotAValue() throws {
        let call = AppService.eventCall(named: AppService.waitForEventToolName, .object([
            "events": .array([.string("agent.finished")]),
            "where": .object(["labels": .string("deploy"),
                              "outcome": .array([.string("done"), .string("nothing_to_do")]),
                              "attempt": .int(2)]),
        ]))
        guard case .success(.wait(_, _, let filters?, _, _, _))? = call else { Issue.record("not read"); return }
        #expect(filters == ["labels": "deploy", "outcome": DetailFilter(anyOf: ["done", "nothing_to_do"])!,
                            "attempt": "2"])

        let bad = AppService.eventCall(named: AppService.waitForEventToolName, .object([
            "events": .array([.string("agent.finished")]),
            "where": .object(["outcome": .object(["is": .string("done")])]),
        ]))
        guard case .failure(let problem)? = bad else { Issue.record("not refused"); return }
        #expect(problem.message.contains("\"outcome\" in where is not a value"))
        #expect(problem.message.contains("a list of those"))
    }
}
