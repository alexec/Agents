import Foundation
import Testing
@testable import AgentsKitCore

/// A Connectors page says "Last update" from its oldest check (#5145), and a row has no clock
/// time of its own, as the web page (`Web/test/sidebar.test.mjs`).
@Suite("MCP health read time")
struct MCPHealthReadAtTests {
    @Test func theOldestCheckAndNoClockOnARow() {
        let old = Date(timeIntervalSinceReferenceDate: 60)
        let new = Date(timeIntervalSinceReferenceDate: 600)
        let github = DaemonAPI.MCPServerHealth(name: "github", folder: nil, transport: .http,
                                               check: .answered, checkedAt: new, tools: 3)
        let local = DaemonAPI.MCPServerHealth(name: "local", folder: nil, transport: .stdio,
                                              check: .failed, checkedAt: old)
        let hosted = DaemonAPI.MCPServerHealth(name: "shared", folder: nil, transport: .stdio, hosted: true)
        #expect(MCPHealthWords.line(github) == "Answered \u{00B7} 3 tools")
        #expect(MCPHealthWords.line(local) == "Didn't answer")
        #expect(MCPHealthWords.readAt([github, local, hosted]) == old)
        #expect(MCPHealthWords.readAt([hosted]) == nil)
    }
}
