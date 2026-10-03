import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The four tools that act on other agents, as the MCP server serves them (028).
///
/// What the daemon decides is `HelperAgentTests`'. What this holds is the half the
/// helper owns: that the tools are offered only to an agent that may use them, that a
/// call reaches the daemon with the agent's words intact, and that a call with its
/// words missing is told so rather than guessed at.
@Suite("The agent tools we serve", .timeLimit(.minutes(1)))
struct AgentToolsServiceTests {
    private actor Calls {
        var seen: [AppService.AgentCall] = []
        func record(_ call: AppService.AgentCall) { seen.append(call) }
    }

    private func pair(managesAgents: Bool = true, calls: Calls = Calls())
        async -> (client: JSONRPCConnection, service: AppService) {
        let (mine, theirs) = PairedTransport.pair()
        let service = AppService(transport: theirs, managesAgents: managesAgents,
                                 agents: { call in
                                     await calls.record(call)
                                     return .shown("done")
                                 })
        let client = JSONRPCConnection(transport: mine)
        await client.start()
        return (client, service)
    }

    private func names(_ client: JSONRPCConnection) async throws -> [String] {
        let result = try await client.call("tools/list", .object([:]))
        return (result["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    private let agentTools = [AppService.startAgentToolName, AppService.stopAgentToolName,
                              AppService.parkAgentToolName, AppService.archiveAgentToolName,
                              AppService.listMyAgentsToolName]

    @Test func anAgentThePersonStartedIsOfferedThem() async throws {
        let (client, service) = await pair()
        let listed = try await names(client)
        for tool in agentTools { #expect(listed.contains(tool), "\(tool)") }
        await service.close()
    }

    @Test func anAgentAnotherAgentStartedIsNotOfferedThem() async throws {
        let (client, service) = await pair(managesAgents: false)
        let listed = try await names(client)
        for tool in agentTools { #expect(!listed.contains(tool), "\(tool)") }
        #expect(listed.contains(AppService.finishTurnToolName), "and keeps the rest")
        await service.close()
    }

    @Test func andIsRefusedIfItCallsOneAnyway() async throws {
        let calls = Calls()
        let (client, service) = await pair(managesAgents: false, calls: calls)
        let result = try await client.call("tools/call", [
            "name": .string("mcp__agents__" + AppService.startAgentToolName),
            "arguments": ["prompt": "Go"],
        ])
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?
            .contains("an agent that another agent started cannot") == true)
        #expect(await calls.seen.isEmpty)
        await service.close()
    }

    @Test func aStartReachesTheDaemonWithItsWords() async throws {
        let calls = Calls()
        let (client, service) = await pair(calls: calls)
        let result = try await client.call("tools/call", [
            "name": .string("mcp__agents__" + AppService.startAgentToolName),
            "arguments": ["prompt": "  Count the files  ", "runtime": "claude",
                          "model": "opus", "permission_mode": "plan"],
        ])
        #expect(result["isError"]?.boolValue == false)
        #expect(await calls.seen == [.start(prompt: "Count the files", runtime: "claude",
                                            model: "opus", permissionMode: "plan")])
        await service.close()
    }

    @Test func stopParkAndListReachTheDaemon() async throws {
        let calls = Calls()
        let (client, service) = await pair(calls: calls)
        _ = try await client.call("tools/call", [
            "name": .string(AppService.stopAgentToolName), "arguments": ["id": "abc"],
        ])
        _ = try await client.call("tools/call", [
            "name": .string(AppService.parkAgentToolName), "arguments": ["id": "abc"],
        ])
        _ = try await client.call("tools/call", [
            "name": .string(AppService.archiveAgentToolName), "arguments": ["id": "abc"],
        ])
        _ = try await client.call("tools/call", ["name": .string(AppService.listMyAgentsToolName)])
        #expect(await calls.seen == [.stop(agentID: "abc"), .park(agentID: "abc"), .archive(agentID: "abc"), .list])
        await service.close()
    }

    @Test func aStartWithNoPromptIsToldAndGoesNowhere() async throws {
        let calls = Calls()
        let (client, service) = await pair(calls: calls)
        let result = try await client.call("tools/call", [
            "name": .string(AppService.startAgentToolName), "arguments": ["prompt": "  "],
        ])
        #expect(result["isError"]?.boolValue == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?
            .hasPrefix("Nothing was started") == true)
        #expect(await calls.seen.isEmpty)
        await service.close()
    }

    @Test func aStopWithNoIdIsToldAndGoesNowhere() async throws {
        let calls = Calls()
        let (client, service) = await pair(calls: calls)
        let result = try await client.call("tools/call", [
            "name": .string(AppService.stopAgentToolName), "arguments": .object([:]),
        ])
        #expect(result["isError"]?.boolValue == true)
        #expect(await calls.seen.isEmpty)
        await service.close()
    }

    @Test func theStartDescriptionCarriesTheLimits() {
        let description = AppService.startAgentTool["description"]?.stringValue ?? ""
        #expect(description.contains("this project"))
        #expect(description.contains("two limits"))
        #expect(description.contains("only the person sets"))
        #expect(description.contains("alongside the rest"))
    }

    /// No helper tool says how many: the project's limits are in each result (#64).
    @Test func noHelperToolHardCodesANumber() {
        for tool in [AppService.startAgentTool, AppService.stopAgentTool, AppService.parkAgentTool,
                     AppService.archiveAgentTool, AppService.listMyAgentsTool] {
            let description = tool["description"]?.stringValue ?? ""
            for number in ["three", "five", " 3 ", " 5 "] {
                #expect(!description.contains(number), "\(tool["name"]?.stringValue ?? "?") says \(number)")
            }
        }
    }
}
