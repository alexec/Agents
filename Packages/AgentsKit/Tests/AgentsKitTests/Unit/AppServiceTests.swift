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
    private func pair(sink: @escaping AppService.Sink,
                      showFile: @escaping AppService.FileSink = { _ in .refused("not expected") })
        async -> (client: JSONRPCConnection, service: AppService) {
        let (mine, theirs) = PairedTransport.pair()
        let service = AppService(transport: theirs, sink: sink, showFile: showFile)
        let client = JSONRPCConnection(transport: mine)
        await client.start()
        return (client, service)
    }

    private func neverCalled() -> AppService.Sink {
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
        #expect(result["protocolVersion"]?.stringValue == AppService.protocolVersion)
        await service.close()
    }

    @Test func bothToolsAreListedWithSchemasTheAgentCanFill() async throws {
        let (client, service) = await pair(sink: neverCalled())
        let result = try await client.call("tools/list", .object([:]))
        let tools = result["tools"]?.arrayValue ?? []
        #expect(tools.compactMap { $0["name"]?.stringValue }
            == [AppService.toolName, AppService.showFileToolName])

        let items = tools.first?["inputSchema"]?["properties"]?["prompts"]?["items"]
        #expect(items?["properties"]?["label"] != nil)
        #expect(items?["properties"]?["prompt"] != nil)

        let showFile = tools.last?["inputSchema"]
        #expect(showFile?["properties"]?["path"] != nil)
        #expect(showFile?["properties"]?["line"] != nil)
        // The line is the optional half: an agent that only knows the file still has
        // a call it can make.
        #expect(showFile?["required"]?.arrayValue?.compactMap { $0.stringValue } == ["path"])
        await service.close()
    }

    @Test func aCallReachesTheSinkAndTheAgentIsToldWhatHappened() async throws {
        let box = Box()
        let (client, service) = await pair(sink: { prompts in
            await box.record(prompts)
            return .shown("Shown above the prompt.")
        })
        let result = try await client.call("tools/call", [
            "name": .string(AppService.toolName),
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
            "name": .string(AppService.toolName),
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
            "name": .string(AppService.toolName),
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
            "name": .string(AppService.toolName),
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
            "name": .string(AppService.toolName),
            "arguments": ["prompts": .array([["prompt": .string(long)]])],
        ])
        #expect(await box.prompts.first?.label.count == SuggestedPrompt.labelLimit)
        #expect(await box.prompts.first?.prompt == long)
        await service.close()
    }

    @Test func nothingSentIsAnErrorTheAgentCanRead() async throws {
        let (client, service) = await pair(sink: neverCalled())
        let result = try await client.call("tools/call", [
            "name": .string(AppService.toolName),
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

    // MARK: Showing a file

    @Test func aFileAndALineReachTheSinkAndTheAgentIsToldWhatHappened() async throws {
        let box = FileBox()
        let (client, service) = await pair(sink: neverCalled(), showFile: { file in
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

    @Test func aPrefixedShowFileIsStillOurTool() async throws {
        let box = FileBox()
        let (client, service) = await pair(sink: neverCalled(), showFile: { file in
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

    /// A relative path is the one mistake an agent will actually make, because that is
    /// what it types in a terminal all day. It is refused here rather than resolved
    /// against a working directory this process does not have.
    @Test func aRelativePathIsRefusedBeforeItReachesTheSink() async throws {
        let (client, service) = await pair(sink: neverCalled(),
                                           showFile: { _ in .shown("should not happen") })
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
        let (client, service) = await pair(sink: neverCalled(), showFile: { file in
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

    private actor Box {
        private(set) var prompts: [SuggestedPrompt] = []
        func record(_ prompts: [SuggestedPrompt]) { self.prompts = prompts }
    }
}
