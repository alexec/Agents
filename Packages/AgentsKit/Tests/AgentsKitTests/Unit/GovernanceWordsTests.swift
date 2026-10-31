import Foundation
import Testing
@testable import AgentsKitCore

/// A person's ask for an MCP server or skill in Settings ▸ Policy, as the window and the Remote say
/// it (#2335). `Web/test/governance.test.mjs` checks the same words on the web page.
@Suite("Governance words")
struct GovernanceWordsTests {
    static func request(_ state: DaemonAPI.CatalogRequestState, kind: DaemonAPI.CatalogKind = .mcp,
                        user: String = "u1", group: String? = nil) -> DaemonAPI.CatalogRequest {
        .init(id: "r-\(user)", kind: kind, name: kind == .mcp ? "github" : "review", user: user, userName: "Sam",
              at: Date(timeIntervalSinceReferenceDate: 700_000_000), state: state, groupName: group)
    }

    @Test func eachRequestSaysWhereItStands() {
        #expect(GovernanceWords.mine(Self.request(.waiting)) == "The MCP server github: waiting for an admin")
        #expect(GovernanceWords.mine(Self.request(.approved))
            == "The MCP server github: approved for you. Add it as you add any MCP server.")
        #expect(GovernanceWords.mine(Self.request(.approved, kind: .skills, group: "Platform"))
            == "The skill review: approved for Platform. Add it as you add any skill.")
        // #2434: the Policy's marketplaces still decide.
        #expect(GovernanceWords.mine(Self.request(.approved), marketplacesLimited: true)
            == "The MCP server github: approved for you. Add it as you add any MCP server. "
            + "Your organisation's Policy still blocks it if no marketplace it allows has it.")
        #expect(GovernanceWords.mine(Self.request(.refused), marketplacesLimited: true) == "The MCP server github: refused")
        #expect(GovernanceWords.mine(Self.request(.refused, kind: .skills)) == "The skill review: refused")
    }

    @Test func anAdminSeesOnlyTheirOwn() {
        let list = [Self.request(.waiting, user: "u1"), Self.request(.waiting, user: "u2")]
        #expect(GovernanceWords.own(list, user: "u1", isAdmin: true).map(\.user) == ["u1"])
        #expect(GovernanceWords.own(list, user: "u1", isAdmin: false).count == 2)
    }

    @Test func anAskNeedsAName() {
        #expect(GovernanceWords.request(kind: .mcp, name: "  ", why: "x") == nil)
        #expect(GovernanceWords.request(kind: .skills, name: " review ", why: "  ")
            == DaemonAPI.CatalogAsk(kind: .skills, name: "review"))
        #expect(GovernanceWords.request(kind: .mcp, name: "github", why: "For reviews")?.why == "For reviews")
    }

    /// The ask, the request and the list fit Packages/Wire, which the Go control plane is made from.
    @Test func theTypesFitTheSchema() throws {
        let schema = try WireSchema(WireSchemaTests.read("daemon.schema.json"))
        let full = DaemonAPI.CatalogRequest(id: "r1", kind: .skills, name: "review", source: "acme", why: "For reviews",
                                            user: "u1", userName: "Sam", at: Date(timeIntervalSinceReferenceDate: 700_000_000),
                                            state: .approved, group: "g1", groupName: "Platform", decidedBy: "Priya",
                                            decidedAt: Date(timeIntervalSinceReferenceDate: 700_000_100))
        #expect(schema.errors(try JSONValue.encoding(full), against: "CatalogRequest") == [])
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.CatalogRequestList(requests: [full, Self.request(.waiting)])),
                              against: "CatalogRequestList") == [])
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.CatalogAsk(kind: .mcp, name: "github", source: "s", why: "w")),
                              against: "CatalogAsk") == [])
        let back = try JSONDecoder().decode(DaemonAPI.CatalogRequest.self, from: JSONEncoder().encode(full))
        #expect(back == full)
    }

    @Test func thePageAndTheAppsTypeTheSameRows() {
        let rows = DaemonAPI.WebSignatures.rows
        #expect(rows.contains { $0.method == DaemonAPI.Method.governanceRequest && $0.params == DaemonAPI.CatalogAsk.self
            && $0.result == DaemonAPI.CatalogRequest.self })
        #expect(rows.contains { $0.method == DaemonAPI.Notification.controlGovernanceRequested
            && $0.params == DaemonAPI.CatalogRequest.self })
    }
    /// #2355: a catalogue sheet offers Ask an Admin under the organisation's refusal only, and says
    /// the refusal in its own words.
    @Test func aPolicyRefusalOffersAskAnAdmin() {
        let line = DaemonAPI.PolicyRefusal(reason: "policy", rule: "marketplaces",
                                           words: "Your organisation does not allow this marketplace.").line
        #expect(GovernanceWords.refusedByPolicy(line))
        #expect(DaemonAPI.MCPCatalogError.failed(line).policyWords == line)
        #expect(DaemonAPI.CatalogError.failed(line).policyWords == line)
        #expect(MCPCatalogWords.sentence(.failed(line)) == line)
        #expect(DaemonAPI.MCPCatalogError.failed("disk full").policyWords == nil)
        #expect(DaemonAPI.MCPCatalogError.unreachable(host: "registry").policyWords == nil)
        #expect(GovernanceWords.askFor(.mcp, "github") == "Ask for the MCP server github")
    }

    @Test func anAskAlreadyMadeIsFoundByName() {
        let list = [Self.request(.waiting), Self.request(.refused, kind: .skills)]
        #expect(GovernanceWords.asked(list, kind: .mcp, name: " GitHub ")?.state == .waiting)
        #expect(GovernanceWords.asked(list, kind: .skills, name: "github") == nil)
        #expect(GovernanceWords.request(kind: .mcp, name: "github", why: "", source: "io.github/github")?.source
            == "io.github/github")
    }
}
