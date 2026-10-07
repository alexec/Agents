import Foundation
import Testing
@testable import AgentsKitCore

/// Which server's tool a runtime called, read by shape (#191, T045), from the #186 probe's
/// own wire lines (`specs/research/186-mcp-apps-acp-probe/`).
@Suite("ACP tool shape")
struct ACPToolShapeTests {
    private let servers = ["kite", "kite-apps", "heron-apps"]

    private func call(_ json: String) throws -> ToolCall {
        let update = try JSONValue.parse(Data(json.utf8))
        guard case .entry(let kind) = SessionUpdate.decode(update) else { throw CocoaError(.coderInvalidValue) }
        switch kind {
        case .toolCall(let call), .toolCallUpdate(let call): return call
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    @Test func codexNamesTheServerAndToolAndGivesTheWholeResult() throws {
        let start = try call(#"{"sessionUpdate":"tool_call","toolCallId":"exec-1","kind":"execute","title":"mcp.kite-apps.kite_apps_weather","rawInput":{"server":"kite-apps","tool":"kite_apps_weather","arguments":{"city":"Paris"}},"_meta":{"is_mcp_tool_call":true}}"#)
        let found = ACPToolShape.candidates(start, servers: servers)
        try #require(found.count == 1)
        #expect(found[0] == .init(server: "kite-apps", tool: "kite_apps_weather", arguments: ["city": "Paris"], exact: true))
        #expect(ACPToolShape.result(start) == nil)

        var done = try call(#"{"sessionUpdate":"tool_call_update","toolCallId":"exec-1","status":"completed","rawOutput":{"result":{"content":[{"type":"text","text":"KITE-WEATHER Paris: 21C, clear"}],"structuredContent":{"city":"Paris","temperatureC":21},"_meta":{"ui":{"resourceUri":"ui://kite-apps/weather"}}},"error":null}}"#)
        done.title = start.title
        let result = try #require(ACPToolShape.result(done))
        #expect(result.drawable)
        #expect(result.value["structuredContent"]?["temperatureC"]?.intValue == 21)
        #expect(result.value["content"]?.arrayValue?.first?["text"]?.stringValue == "KITE-WEATHER Paris: 21C, clear")
    }

    @Test func claudeNamesItWithMcpUnderscoresAndGivesStructuredContentAsAString() throws {
        let start = try call(#"{"sessionUpdate":"tool_call","toolCallId":"toolu_1","title":"mcp__kite-apps__kite_apps_weather","rawInput":{"city":"Paris"}}"#)
        let found = ACPToolShape.candidates(start, servers: servers)
        try #require(found.count == 1)
        #expect(found[0] == .init(server: "kite-apps", tool: "kite_apps_weather", arguments: ["city": "Paris"], exact: true))

        let done = try call(#"{"sessionUpdate":"tool_call_update","toolCallId":"toolu_1","status":"completed","_meta":{"claudeCode":{"toolName":"mcp__kite-apps__kite_apps_weather"}},"rawOutput":"{\"city\":\"Paris\",\"temperatureC\":21}"}"#)
        let result = try #require(ACPToolShape.result(done))
        #expect(result.drawable)
        #expect(result.value["structuredContent"]?["city"]?.stringValue == "Paris")
    }

    @Test func copilotJoinsThemWithADashAndTheLongestServerWins() throws {
        let start = try call(#"{"sessionUpdate":"tool_call","toolCallId":"toolu_2","title":"kite-apps-kite_apps_weather","kind":"other","rawInput":{"city":"Paris"}}"#)
        let found = ACPToolShape.candidates(start, servers: servers)
        try #require(!found.isEmpty)
        #expect(found[0] == .init(server: "kite-apps", tool: "kite_apps_weather", arguments: ["city": "Paris"], exact: false))
        // The shorter name is a reading too, checked against the catalog after.
        #expect(found.contains { $0.server == "kite" && $0.tool == "apps-kite_apps_weather" })

        let done = try call(#"{"sessionUpdate":"tool_call_update","toolCallId":"toolu_2","status":"completed","rawOutput":{"content":"KITE-WEATHER Paris","contents":[{"type":"text","text":"KITE-WEATHER Paris"}],"structuredContent":{"city":"Paris"}}}"#)
        let result = try #require(ACPToolShape.result(done))
        #expect(result.drawable)
        #expect(result.value["content"]?.arrayValue?.count == 1)
    }

    @Test func openCodeGivesTextOnlySoItIsNotDrawable() throws {
        let start = try call(#"{"sessionUpdate":"tool_call_update","toolCallId":"call_3","status":"in_progress","title":"kite-apps_kite_apps_weather","rawInput":{"city":"Paris"}}"#)
        let found = ACPToolShape.candidates(start, servers: servers)
        #expect(found.first == .init(server: "kite-apps", tool: "kite_apps_weather", arguments: ["city": "Paris"], exact: false))

        let done = try call(#"{"sessionUpdate":"tool_call_update","toolCallId":"call_3","status":"completed","rawOutput":{"output":"KITE-WEATHER Paris","metadata":{"truncated":false}}}"#)
        let result = try #require(ACPToolShape.result(done))
        #expect(!result.drawable)
        #expect(result.value["content"]?.arrayValue?.first?["text"]?.stringValue == "KITE-WEATHER Paris")
    }

    @Test func aToolOfNoServerTheSessionHasIsNoCall() throws {
        let shell = try call(#"{"sessionUpdate":"tool_call","toolCallId":"t","title":"Read file","rawInput":{"path":"a"}}"#)
        #expect(ACPToolShape.candidates(shell, servers: servers).isEmpty)
        let elsewhere = try call(#"{"sessionUpdate":"tool_call","toolCallId":"t","title":"x","rawInput":{"server":"otter","tool":"a"}}"#)
        #expect(ACPToolShape.candidates(elsewhere, servers: servers).isEmpty)
        let mcp = try call(#"{"sessionUpdate":"tool_call","toolCallId":"t","title":"mcp__otter__a"}"#)
        #expect(ACPToolShape.candidates(mcp, servers: servers).isEmpty)
    }

    @Test func aFailedCallIsAnErrorResult() throws {
        let failed = try call(#"{"sessionUpdate":"tool_call_update","toolCallId":"t","status":"failed","rawOutput":{"result":null,"error":"boom"}}"#)
        let result = try #require(ACPToolShape.result(failed))
        #expect(result.value["isError"]?.boolValue == true)
        #expect(!result.drawable)
    }
}
