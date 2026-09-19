import Foundation
import Testing
@testable import AgentsKit

/// The MCP server we hand to every agent.
///
/// It is four methods over a pipe, and a runtime that cannot complete the handshake
/// never sees the tool at all, so these are about the shape of the answers as much as
/// about what a call does.
@Suite("The suggestion tool we serve", .timeLimit(.minutes(1)))
struct SuggestionServiceTests {
    /// A service on one end of a pipe and a plain JSON-RPC client on the other, which
    /// is what a runtime is here.
    private func pair(sink: @escaping SuggestionService.Sink)
        async -> (client: JSONRPCConnection, service: SuggestionService) {
        let (mine, theirs) = PairedTransport.pair()
        let service = SuggestionService(transport: theirs, sink: sink)
        let client = JSONRPCConnection(transport: mine)
        await client.start()
        return (client, service)
    }

    private func neverCalled() -> SuggestionService.Sink {
        { _ in .refused("not expected") }
    }

    @Test func itAnswersTheHandshakeWithTheVersionTheClientAsked() async throws {
        let (client, service) = await pair(sink: neverCalled())
        let result = try await client.call("initialize", ["protocolVersion": "2025-03-26"])
        #expect(result["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(result["serverInfo"]?["name"]?.stringValue == "agents")
        // The tools capability is what makes a client ask for the list at all.
        #expect(result["capabilities"]?["tools"] != nil)
        await service.close()
    }

    @Test func aClientThatNamesNoVersionGetsOurs() async throws {
        let (client, service) = await pair(sink: neverCalled())
        let result = try await client.call("initialize", .object([:]))
        #expect(result["protocolVersion"]?.stringValue == SuggestionService.protocolVersion)
        await service.close()
    }

    @Test func theToolIsListedWithASchemaTheAgentCanFill() async throws {
        let (client, service) = await pair(sink: neverCalled())
        let result = try await client.call("tools/list", .object([:]))
        let tools = result["tools"]?.arrayValue ?? []
        #expect(tools.count == 1)
        #expect(tools.first?["name"]?.stringValue == SuggestionService.toolName)
        let items = tools.first?["inputSchema"]?["properties"]?["prompts"]?["items"]
        #expect(items?["properties"]?["label"] != nil)
        #expect(items?["properties"]?["prompt"] != nil)
        await service.close()
    }

    @Test func aCallReachesTheSinkAndTheAgentIsToldWhatHappened() async throws {
        let box = Box()
        let (client, service) = await pair(sink: { prompts in
            await box.record(prompts)
            return .shown("Shown above the prompt.")
        })
        let result = try await client.call("tools/call", [
            "name": .string(SuggestionService.toolName),
            "arguments": ["prompts": .array([
                ["label": "Run the tests", "prompt": "Run the tests and fix what fails"],
            ])],
        ])
        #expect(await box.prompts.map(\.label) == ["Run the tests"])
        #expect(await box.prompts.map(\.prompt) == ["Run the tests and fix what fails"])
        #expect(result["isError"]?.boolValue == false)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "Shown above the prompt.")
        await service.close()
    }

    /// The Claude adapter prefixes the tools of an MCP server with the server's name,
    /// so the name that comes back is not the name we gave it.
    @Test func aPrefixedToolNameIsStillOurTool() async throws {
        let box = Box()
        let (client, service) = await pair(sink: { prompts in
            await box.record(prompts)
            return .shown("ok")
        })
        _ = try await client.call("tools/call", [
            "name": "mcp__agents__suggest_next_prompts",
            "arguments": ["prompts": .array([["label": "One", "prompt": "Do one"]])],
        ])
        #expect(await box.prompts.count == 1)
        await service.close()
    }

    @Test func aRefusalIsAToolErrorRatherThanAProtocolError() async throws {
        let (client, service) = await pair(sink: { _ in .refused("That conversation is closed.") })
        let result = try await client.call("tools/call", [
            "name": .string(SuggestionService.toolName),
            "arguments": ["prompts": .array([["label": "One", "prompt": "Do one"]])],
        ])
        // Not a JSON-RPC failure: the agent is meant to read this and carry on.
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "That conversation is closed.")
        await service.close()
    }

    @Test func fourIsTheMostThatGetThrough() async throws {
        let box = Box()
        let (client, service) = await pair(sink: { prompts in
            await box.record(prompts)
            return .shown("ok")
        })
        let many = (1...9).map { JSONValue.object(["label": .string("\($0)"), "prompt": .string("Do \($0)")]) }
        _ = try await client.call("tools/call", [
            "name": .string(SuggestionService.toolName),
            "arguments": ["prompts": .array(many)],
        ])
        #expect(await box.prompts.count == SuggestedPrompt.limit)
        #expect(await box.prompts.map(\.label) == ["1", "2", "3", "4"])
        await service.close()
    }

    /// One blank entry must not cost the other three.
    @Test func anEmptyPromptIsDroppedAndTheRestAreKept() async throws {
        let box = Box()
        let (client, service) = await pair(sink: { prompts in
            await box.record(prompts)
            return .shown("ok")
        })
        _ = try await client.call("tools/call", [
            "name": .string(SuggestionService.toolName),
            "arguments": ["prompts": .array([
                ["label": "Blank", "prompt": "   "],
                ["label": "Real", "prompt": "Do the real one"],
            ])],
        ])
        #expect(await box.prompts.map(\.label) == ["Real"])
        await service.close()
    }

    /// A label is what fits on the chip. A prompt with no label at all still gets one.
    @Test func aMissingLabelBecomesTheStartOfThePrompt() async throws {
        let box = Box()
        let (client, service) = await pair(sink: { prompts in
            await box.record(prompts)
            return .shown("ok")
        })
        let long = String(repeating: "a", count: 200)
        _ = try await client.call("tools/call", [
            "name": .string(SuggestionService.toolName),
            "arguments": ["prompts": .array([["prompt": .string(long)]])],
        ])
        #expect(await box.prompts.first?.label.count == SuggestedPrompt.labelLimit)
        #expect(await box.prompts.first?.prompt == long)
        await service.close()
    }

    @Test func nothingSentIsAnErrorTheAgentCanRead() async throws {
        let (client, service) = await pair(sink: neverCalled())
        let result = try await client.call("tools/call", [
            "name": .string(SuggestionService.toolName),
            "arguments": ["prompts": .array([])],
        ])
        #expect(result["isError"]?.boolValue == true)
        await service.close()
    }

    @Test func someOtherToolIsNotOurs() async throws {
        let (client, service) = await pair(sink: neverCalled())
        await #expect(throws: JSONRPCError.self) {
            _ = try await client.call("tools/call", ["name": "rm_rf", "arguments": .object([:])])
        }
        await service.close()
    }

    private actor Box {
        private(set) var prompts: [SuggestedPrompt] = []
        func record(_ prompts: [SuggestedPrompt]) { self.prompts = prompts }
    }
}
