import Foundation
import Testing
@testable import AgentsKit

/// Grok hides the app's MCP tools behind a search. A session is handed the schemas
/// instead, under the catalog names Grok calls, and only for the tools that session
/// will actually be offered.
@Suite("Grok tool preface", .timeLimit(.minutes(1)))
struct GrokToolPrefaceTests {
    @Test func theSchemasNameEveryOfferedToolAndNotTheOlderNames() {
        let rules = GrokToolPreface.rules(managesAgents: true)
        #expect(rules.contains("Do not call search_tool"))
        #expect(rules.contains("use_tool"))
        let offered = AppService.tools(managesAgents: true, movesItself: false)
            .compactMap { $0["name"]?.stringValue }
        for name in offered {
            #expect(rules.contains(GrokToolPreface.catalogName(name)), "\(name)")
        }
        #expect(rules.contains("permission-mode: plan"))
        for retired in AppTool.retiredEndOfTurn { #expect(!rules.contains(retired)) }
        // Grok cannot carry its conversation into another folder (053).
        #expect(!rules.contains("leave_worktree"))
    }

    @Test func aHelperIsNotToldHowToStartAnAgent() {
        let rules = GrokToolPreface.rules(managesAgents: false)
        #expect(rules.contains(GrokToolPreface.catalogName(AppTool.showFile)))
        #expect(!rules.contains(GrokToolPreface.catalogName(AppTool.startAgent)))
        #expect(!rules.contains(GrokToolPreface.catalogName(AppTool.stopAgent)))
        #expect(!rules.contains(GrokToolPreface.catalogName(AppTool.listMyAgents)))
        #expect(rules.contains(GrokToolPreface.catalogName(AppTool.leaseResource)))
        // Grok's own question tool never reaches us, so this is its only way to ask.
        #expect(rules.contains(GrokToolPreface.catalogName(AppTool.askForm)))
    }

    @Test func aGrokSessionCarriesTheRulesAndNoOtherRuntimeDoes() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GrokToolPrefaceTests-\(UUID().uuidString)", isDirectory: true)
        let work = base.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: base.appending(path: "root"))
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())

        let full = await core.sessionMeta(runtimeID: "grok", cwd: work, managesAgents: true)
        let helper = await core.sessionMeta(runtimeID: "grok", cwd: work, managesAgents: false)
        let claude = await core.sessionMeta(runtimeID: "claude", cwd: work)

        let fullRules = try #require(full?["rules"]?.stringValue)
        #expect(fullRules == GrokToolPreface.rules(managesAgents: true))
        #expect(full?["agentProfile"]?["tools"] != nil, "the allow list is still there")
        #expect(helper?["rules"]?.stringValue == GrokToolPreface.rules(managesAgents: false))
        #expect(claude?["rules"] == nil)
    }
}
