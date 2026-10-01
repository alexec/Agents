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
                      askForm: @escaping AppService.AskFormSink = { _, _ in .refused("not expected") },
                      finishTurn: @escaping AppService.FinishSink = { _, _, _, _, _ in
                          .refused("not expected")
                      })
        async -> (client: JSONRPCConnection, service: AppService) {
        let (mine, theirs) = PairedTransport.pair()
        let service = AppService(transport: theirs, finishTurn: finishTurn,
                                 showFile: showFile, askForm: askForm)
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
        // The one call that ends a turn first, the ones that act mid-turn after it.
        // The two older names for its halves are gone (023 R5).
        // The four agent tools (028 + park) sit after the workflow tool, for an agent
        // that may use them — which is the default.
        // archive_agent is no longer offered. The three lease tools (036) follow
        // them, for every agent, then the three event tools (042). Moving (053) rides on
        // finish_turn. The two session tools (065) sit after the agent tools, for every
        // agent.
        #expect(tools.compactMap { $0["name"]?.stringValue }
            == [AppService.finishTurnToolName, AppService.showFileToolName,
                AppService.workflowToolName, AppService.askFormToolName,
                AppService.startAgentToolName, AppService.stopAgentToolName,
                AppService.parkAgentToolName, AppService.listMyAgentsToolName,
                AppService.listSessionsToolName, AppService.readSessionToolName,
                AppService.leaseResourceToolName, AppService.releaseResourceToolName,
                AppService.listResourcesToolName,
                AppService.waitForEventToolName, AppService.cancelWaitToolName,
                AppService.publishEventToolName])

        let finish = tools.first?["inputSchema"]
        #expect(finish?["properties"]?["outcome"]?["enum"]?.arrayValue?
            .compactMap { $0.stringValue }
            == WorkOutcome.allCases.map(\.rawValue))
        // The outcome and its words are the call; the name and the chips ride along.
        #expect(finish?["required"]?.arrayValue?.compactMap { $0.stringValue }
            == ["outcome", "message"])
        #expect(finish?["properties"]?["title"]?["type"]?.stringValue == "string")
        // One suggestion, as an object; the list is read but no longer offered (031).
        let next = finish?["properties"]?["next_prompt"]
        #expect(next?["type"]?.stringValue == "object")
        #expect(next?["required"]?.arrayValue?.compactMap { $0.stringValue }
            == ["label", "prompt"])
        #expect(finish?["properties"]?["next_prompts"] == nil)

        let showFile = tools[1]["inputSchema"]
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

        let workflows = tools[2]["inputSchema"]
        #expect(workflows?["properties"]?["action"]?["enum"]?.arrayValue?
            .compactMap { $0.stringValue } == ["list", "read", "write", "remove"])
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
        let description = result["tools"]?.arrayValue?[1]["description"]?.stringValue ?? ""
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

    private actor FinishBox {
        var calls = 0
        var outcome = ""
        var message = ""
        var prompts: [SuggestedPrompt] = []
        var title: String?
        var words = AppService.BlockWords.none
        func record(_ outcome: String, _ message: String, _ prompts: [SuggestedPrompt],
                    _ title: String?, _ words: AppService.BlockWords) {
            calls += 1
            self.words = words
            self.outcome = outcome
            self.message = message
            self.prompts = prompts
            self.title = title
        }
    }

    private func finishing(_ box: FinishBox) -> AppService.FinishSink {
        { outcome, message, prompts, title, words in
            await box.record(outcome, message, prompts, title, words)
            return .shown("Noted.")
        }
    }

    // MARK: Blocked (039)

    /// The sixth outcome is offered, with what it carries.
    @Test func blockedIsOfferedWithWhatItCarries() async throws {
        let properties = AppService.finishTurnTool["inputSchema"]?["properties"]
        #expect(properties?["outcome"]?["enum"]?.arrayValue?.contains("blocked") == true)
        #expect(properties?["waiting_on"]?["type"]?.stringValue == "array")
        #expect(properties?["check_again_in_minutes"]?["maximum"]?.intValue == 1440)
        #expect(AppService.finishTurnTool["description"]?.stringValue?.contains("blocked") == true)
    }

    @Test func aBlockedCallCarriesItsWaitsAndTimeToTheSink() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let result = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "blocked", "message": "Waiting on the helpers.",
                          "title": "Waiting", "waiting_on": ["A", "B"],
                          "check_again_in_minutes": 25],
        ])
        #expect(result["isError"]?.boolValue == false)
        #expect(await box.words == AppService.BlockWords(waitingOn: ["A", "B"], checkAgainInMinutes: 25))
        await service.close()
    }

    /// Contract §1: the block's arguments go with blocked alone, and the minutes are
    /// whole and in range. Refused before the daemon is asked.
    @Test func blockArgumentsAreRefusedWhereTheyDoNotBelong() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let cases: [JSONValue] = [
            ["outcome": "done", "message": "m", "title": "t", "waiting_on": ["A"]],
            ["outcome": "done", "message": "m", "title": "t", "check_again_in_minutes": 5],
            ["outcome": "blocked", "message": "m", "title": "t", "check_again_in_minutes": 0],
            ["outcome": "blocked", "message": "m", "title": "t", "check_again_in_minutes": 1441],
            ["outcome": "blocked", "message": "m", "title": "t", "check_again_in_minutes": 2.5],
        ]
        for arguments in cases {
            let result = try await client.call("tools/call", [
                "name": .string(AppService.finishTurnToolName), "arguments": arguments,
            ])
            #expect(result["isError"]?.boolValue == true, "\(arguments)")
        }
        #expect(await box.calls == 0)
        await service.close()
    }

    // MARK: Parked or archived once the turn ends

    @Test func afterwardsIsOffered() async throws {
        let properties = AppService.finishTurnTool["inputSchema"]?["properties"]
        #expect(properties?["afterwards"]?["enum"]?.arrayValue == ["park"])
        #expect(AppService.finishTurnTool["description"]?.stringValue?.contains("afterwards") == true)
    }

    @Test func anAskThatFitsTheOutcomeReachesTheSink() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let result = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Merged and cleaned up.",
                          "afterwards": "park"],
        ])
        #expect(result["isError"]?.boolValue == false)
        #expect(await box.words.afterwards == .park)
        await service.close()
    }

    /// An older conversation may still send archive. The call reaches the sink; the
    /// daemon keeps the outcome and declines the ask.
    @Test func anArchiveAskStillReachesTheSink() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let result = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Merged and cleaned up.",
                          "afterwards": "archive"],
        ])
        #expect(result["isError"]?.boolValue == false)
        #expect(await box.words.afterwards == .archive)
        await service.close()
    }

    /// A word that is neither, and each park pairing that would bury something,
    /// refused before the daemon is asked.
    @Test func anAskThatDoesNotFitIsRefusedWhole() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let cases: [(JSONValue, String)] = [
            (["outcome": "done", "message": "m", "afterwards": "delete"], AfterTurn.unknown),
            (["outcome": "needs_answer", "message": "m", "afterwards": "park"], AfterTurn.park.refusal),
            (["outcome": "stuck", "message": "m", "afterwards": "park"], AfterTurn.park.refusal),
            (["outcome": "blocked", "message": "m", "check_again_in_minutes": 5, "afterwards": "park"],
             AfterTurn.park.refusal),
        ]
        for (arguments, refusal) in cases {
            let result = try await client.call("tools/call", [
                "name": .string(AppService.finishTurnToolName), "arguments": arguments,
            ])
            #expect(result["isError"]?.boolValue == true, "\(arguments)")
            #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == refusal, "\(arguments)")
        }
        #expect(await box.calls == 0)
        await service.close()
    }

    @Test func aFinishCallReachesTheSinkWithBothHalves() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let result = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "  Renamed 14 call sites.  ",
                          "title": "Call sites renamed",
                          "next_prompts": .array([
                              ["label": "Run the tests", "prompt": "Run the tests and fix what fails"],
                              ["label": "Push", "prompt": "Push the branch"],
                          ])],
        ])
        #expect(result["isError"]?.boolValue == false)
        #expect(await box.outcome == "done")
        // Trimmed on the way through, as a report is.
        #expect(await box.message == "Renamed 14 call sites.")
        #expect(await box.prompts.map(\.label) == ["Run the tests"])
        #expect(await box.title == "Call sites renamed")
        await service.close()
    }

    /// The chips ride along; their absence is not a fault. Left out or sent empty,
    /// the outcome still lands (FR-003).
    @Test func aFinishCallWithNoPromptsStillReachesTheSink() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        for arguments in [
            JSONValue.object(["outcome": "done", "message": "All done.", "title": "Tidied"]),
            JSONValue.object(["outcome": "done", "message": "All done.", "title": "Tidied",
                              "next_prompts": .array([])]),
        ] {
            let result = try await client.call("tools/call", [
                "name": .string(AppService.finishTurnToolName), "arguments": arguments,
            ])
            #expect(result["isError"]?.boolValue == false)
            #expect(await box.prompts.isEmpty)
        }
        #expect(await box.calls == 2)
        await service.close()
    }

    /// Refused whole, prompts included, and the five are named so the agent can call
    /// again with a word we know (Research R4).
    @Test func aFinishCallWithAnUnknownOutcomeIsRefusedWhole() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let result = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "succeeded", "message": "all good", "title": "Tidied",
                          "next_prompts": .array([["label": "A", "prompt": "Do A"]])],
        ])
        #expect(result["isError"]?.boolValue == true)
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("nothing_to_do"))
        #expect(text.contains("partly_done"))
        #expect(await box.calls == 0)
        await service.close()
    }

    @Test func aFinishCallWithNoWordsIsRefused() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        for message in ["", "   "] {
            let result = try await client.call("tools/call", [
                "name": .string(AppService.finishTurnToolName),
                "arguments": ["outcome": "done", "message": .string(message), "title": "Tidied"],
            ])
            #expect(result["isError"]?.boolValue == true)
            #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?
                .contains("how it went") == true)
        }
        #expect(await box.calls == 0)
        await service.close()
    }

    @Test func aPrefixedFinishCallIsStillOurTool() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let result = try await client.call("tools/call", [
            "name": "mcp__agents__finish_turn",
            "arguments": ["outcome": "stuck", "message": "No signing certificate.",
                          "title": "Signing the build"],
        ])
        #expect(result["isError"]?.boolValue == false)
        #expect(await box.outcome == "stuck")
        await service.close()
    }

    @Test func aRefusalIsAToolErrorRatherThanAProtocolError() async throws {
        let (client, service) = await pair(finishTurn: { _, _, _, _, _ in
            .refused("That conversation is closed.")
        })
        let result = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "All done."],
        ])
        // Not a JSON-RPC failure: the agent is meant to read this and carry on.
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "That conversation is closed.")
        await service.close()
    }

    /// A label is what fits on the chip. A prompt with no label at all still gets one.
    @Test func aMissingLabelBecomesTheStartOfThePrompt() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let long = String(repeating: "a", count: 200)
        _ = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "All done.",
                          "next_prompt": ["prompt": .string(long)]],
        ])
        #expect(await box.prompts.first?.label.count == SuggestedPrompt.labelLimit)
        #expect(await box.prompts.first?.prompt == long)
        await service.close()
    }

    @Test func fiveNextPromptsBecomeTheFirst() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let many = (1...5).map { JSONValue.object(["label": .string("\($0)"), "prompt": .string("Do \($0)")]) }
        _ = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Done.", "title": "Tidied",
                          "next_prompts": .array(many)],
        ])
        #expect(await box.prompts.map(\.label) == ["1"])
        await service.close()
    }

    /// What a fresh agent is told to send (031).
    @Test func oneNextPromptReachesTheSink() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        let result = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Done.", "title": "Tidied",
                          "next_prompt": ["label": "Push", "prompt": "Push the branch"]],
        ])
        #expect(result["isError"]?.boolValue == false)
        #expect(await box.prompts.map(\.prompt) == ["Push the branch"])
        await service.close()
    }

    /// Both forms in one call: the one is what the agent meant, and wins.
    @Test func theOneWinsOverTheList() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        _ = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Done.", "title": "Tidied",
                          "next_prompt": ["label": "One", "prompt": "Do one"],
                          "next_prompts": .array([["label": "Listed", "prompt": "Do listed"]])],
        ])
        #expect(await box.prompts.map(\.label) == ["One"])
        await service.close()
    }

    /// A list whose first entry is blank keeps the first that is not.
    @Test func aBlankFirstEntryGivesWayToTheNext() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        _ = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Done.", "title": "Tidied",
                          "next_prompts": .array([["label": "Blank", "prompt": "  "],
                                                  ["label": "Real", "prompt": "Do it"]])],
        ])
        #expect(await box.prompts.map(\.label) == ["Real"])
        await service.close()
    }

    // MARK: The title

    /// Sent when the goal is named or changes, and left out otherwise. A call without
    /// one — or with one that cleans to nothing — still lands, carrying no title, so
    /// the row keeps the name it has.
    @Test func aFinishCallWithNoTitleLandsWithoutOne() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        for arguments in [
            JSONValue.object(["outcome": "done", "message": "All done."]),
            JSONValue.object(["outcome": "done", "message": "All done.", "title": ""]),
            JSONValue.object(["outcome": "done", "message": "All done.", "title": "  \n\t "]),
        ] {
            let result = try await client.call("tools/call", [
                "name": .string(AppService.finishTurnToolName), "arguments": arguments,
            ])
            #expect(result["isError"]?.boolValue == false)
            #expect(await box.title == nil)
            #expect(await box.message == "All done.")
        }
        #expect(await box.calls == 3)
        await service.close()
    }

    /// The words an agent reads decide what it names: the goal, kept while it holds,
    /// not the step it just took. Checked on the tool and on the briefing alike, since
    /// either alone left titles naming the turn.
    @Test func theTitleIsDescribedAsTheGoal() {
        let description = AppService.finishTurnTool["description"]?.stringValue ?? ""
        #expect(description.contains("its goal, not the step you just took"))
        #expect(description.contains("leave it out otherwise and the name stays"))
        #expect(!description.contains("Give a fresh one every time"))
        let property = AppService.finishTurnTool["inputSchema"]?["properties"]?["title"]?["description"]?
            .stringValue ?? ""
        #expect(property.contains("goal"))
        #expect(property.contains("leave it out to keep the name"))
        #expect(Briefing.finish.contains("title for the conversation's goal (only when it changes)"))
        #expect(!Briefing.finish.contains("doing now"))
    }

    /// A title is a row's name: one line, spaces collapsed, no longer than a
    /// prompt-made title may be.
    @Test func aTitleIsMadeFitForARow() async throws {
        let box = FinishBox()
        let (client, service) = await pair(finishTurn: finishing(box))
        _ = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Done.",
                          "title": "  Login redirect\n   fixed  "],
        ])
        #expect(await box.title == "Login redirect fixed")

        let long = String(repeating: "word ", count: 40)
        _ = try await client.call("tools/call", [
            "name": .string(AppService.finishTurnToolName),
            "arguments": ["outcome": "done", "message": "Done.", "title": .string(long)],
        ])
        let clipped = try #require(await box.title)
        #expect(clipped.count == 80)
        #expect(clipped.hasSuffix("…"))
        await service.close()
    }

    /// The tool says what the title is for, where an agent reads it.
    @Test func theToolSaysWhatTheTitleIsFor() async throws {
        let (client, service) = await pair()
        let result = try await client.call("tools/list", .object([:]))
        let description = result["tools"]?.arrayValue?.first?["description"]?.stringValue ?? ""
        #expect(description.contains("The title is the name on that row"))
        await service.close()
    }

    /// The app tells its own tools apart by the end of their names (a runtime may
    /// prefix them), so no tool's name may end with another's. 036's release_resource
    /// once ended with lease_resource, and every release became an extension.
    @Test func noToolNameEndsWithAnother() {
        let names = [AppTool.finishTurn, AppTool.showFile, AppTool.manageWorkflows, AppTool.askForm,
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
        #expect(description.hasSuffix(EventCatalogue.describe()))
    }
}
