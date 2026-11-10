import Foundation
import Testing
import AgentsKitCore

/// Allow, Ask or Off for each tool of a connector (#4099).
@Suite("Connector tool levels")
struct ConnectorToolWordsTests {
    @Test func aToolsDefaultIsAskWhenItWritesAndAllowWhenItReads() {
        let writes = DaemonAPI.MCPToolRow(name: "create_issue", writes: true, level: .ask)
        let reads = DaemonAPI.MCPToolRow(name: "get_issue", writes: false, level: .allow)
        #expect(ConnectorToolWords.defaultLevel(writes, writes: nil) == .ask)
        #expect(ConnectorToolWords.defaultLevel(writes, writes: .off) == .off)
        #expect(ConnectorToolWords.defaultLevel(reads, writes: .off) == .allow)
        let capped = DaemonAPI.MCPToolRow(name: "get_issue", writes: false, level: .ask, cap: .ask)
        #expect(ConnectorToolWords.defaultLevel(capped, writes: nil) == .ask)
        #expect(ConnectorToolWords.byDefault(.ask) == "Default (Ask)")
    }

    @Test func aLayerKeepsItsConnectorToolsThroughASave() throws {
        let json = #"{"connectorTools":{"github":{"writes":"ask","tools":{"delete_repo":"off"}}},"sandbox":"on"}"#
        let rules = try JSONDecoder().decode(DaemonAPI.PolicyRules.self, from: Data(json.utf8))
        #expect(rules.connectorTools?["github"]?.tools?["delete_repo"] == .off)
        let again = try JSONDecoder().decode(DaemonAPI.PolicyRules.self, from: JSONEncoder().encode(rules))
        #expect(again == rules)
    }

    @Test func anUnknownLevelReadsAsAsk() throws {
        let level = try JSONDecoder().decode([DaemonAPI.ConnectorToolLevel].self, from: Data(#"["never","off"]"#.utf8))
        #expect(level == [.ask, .off])
        #expect(PolicyLayersWords.ruleTitle("connectorTools") == "Connector tools")
    }
}
