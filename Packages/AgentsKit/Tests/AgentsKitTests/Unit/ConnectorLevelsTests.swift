import Foundation
import Testing
@testable import AgentsKitCore

/// A connector's five levels (#1428): read from the host's row, in the words the web page has
/// (`Web/test/sidebar.test.mjs`).
@Suite("Connector levels")
struct ConnectorLevelsTests {
    @Test func theWords() {
        let github = DaemonAPI.MCPLevels(tools: true, events: true)
        #expect(MCPHealthWords.levels(github).map(\.name) == ["Tools", "Events", "Views", "Workflows", "Tested"])
        #expect(MCPHealthWords.levels(github).filter(\.reached).map(\.name) == ["Tools", "Events"])
        #expect(MCPHealthWords.levels(nil).filter(\.reached).isEmpty)
        #expect(MCPHealthWords.levelsSentence(github) == "Reaches Tools, Events. Not yet Views, Workflows, Tested.")
        #expect(MCPHealthWords.levelsSentence(nil) == "Its levels show once its host has checked it.")
        #expect(MCPHealthWords.levelsSentence(DaemonAPI.MCPLevels()) == "Reaches none of the five levels yet.")
        #expect(MCPHealthWords.levelsSentence(DaemonAPI.MCPLevels(tools: true, events: true, views: true,
                                                                  workflows: true, tested: true))
                == "Reaches all five levels.")
    }

    @Test func aRowFromTheHost() throws {
        let json = #"""
        {"name":"linear","transport":"stdio","hosted":true,"check":"unchecked","madeByAgents":true,
         "levels":{"tools":false,"events":true,"views":false,"workflows":false,"tested":false}}
        """#
        let row = try JSONDecoder().decode(DaemonAPI.MCPServerHealth.self, from: Data(json.utf8))
        #expect(row.madeByAgents == true)
        #expect(row.levels == DaemonAPI.MCPLevels(events: true))
        let older = try JSONDecoder().decode(DaemonAPI.MCPServerHealth.self,
                                             from: Data(#"{"name":"x","transport":"http","hosted":false,"check":"answered"}"#.utf8))
        #expect(older.levels == nil && older.madeByAgents == nil)
    }
}
