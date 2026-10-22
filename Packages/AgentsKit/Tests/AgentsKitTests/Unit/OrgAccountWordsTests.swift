import Foundation
import Testing
@testable import AgentsKitCore

/// The organisation's ways to the model as the window and the Remote say them (#999, T029):
/// the kinds, a runtime's `reach` rule, a member's line and the refusals of the contract.
/// `Web/test/orgAccounts.test.mjs` checks the same words on the web page.
@Suite("Org account words")
struct OrgAccountWordsTests {
    @Test func eachKindHasItsName() {
        #expect(["key", "bedrock", "vertex", "azure", "baseURL"].map(OrgAccountWords.kindName)
            == ["Org key", "Amazon Bedrock", "Google Vertex AI", "Microsoft Azure", "Gateway"])
    }

    @Test func aReachRuleSaysTheWaysAllowed() {
        #expect(OrgAccountWords.reachWords(["gateway", "orgKey"]) == "Org key or gateway only")
        #expect(OrgAccountWords.reachWords(["signIn"]) == "Own sign-in only")
        #expect(OrgAccountWords.reachWords(["orgKey"]) == "Org key only")
        #expect(OrgAccountWords.reachWords(["signIn", "orgKey", "gateway"]) == "Any way")
    }

    @Test func thePolicyPaneSaysEachRuntimesWays() {
        let policy = DaemonAPI.OrgPolicy(version: 1, issued: .now, changedBy: .init(user: "u"),
                                         runtimes: ["claude": .init(reach: ["orgKey", "gateway"]), "codex": .init()],
                                         notices: .init(antigravityTerms: "accepted"))
        let words = Dictionary(uniqueKeysWithValues: OrgPolicyWords.rules(policy).map { ($0.title, $0.words) })
        #expect(words["Claude reaches the model by"] == "Org key or gateway only")
        #expect(words["Codex reaches the model by"] == nil)
        #expect(words["Antigravity’s terms"] == "Reviewed by your organisation")
    }

    @Test func everyRuntimeNamedOnlyForItsWaysSaysEveryRuntime() {
        var runtimes: [String: DaemonAPI.PolicyRuntimeRule] = [:]
        for id in OrgPolicyWords.runtimeNames.keys { runtimes[id] = .init() }
        runtimes["claude"] = .init(reach: ["signIn"])
        let policy = DaemonAPI.OrgPolicy(version: 1, issued: .now, changedBy: .init(user: "u"), runtimes: runtimes)
        #expect(OrgPolicyWords.rules(policy).first?.words == "Every runtime")
    }

    @Test func aMemberSeesTheNameKindAndRuntimesOnly() throws {
        let json = #"{"routes":[{"id":"acme","name":"Acme Bedrock","kind":"bedrock","runtimes":["claude","opencode"],"defaultFor":["claude"]}]}"#
        let mine = try JSONDecoder().decode(DaemonAPI.OrgRoutesMine.self, from: Data(json.utf8))
        #expect(mine.routes.map(OrgAccountWords.mineLine) == ["Amazon Bedrock · Claude, OpenCode · default for Claude"])
    }

    @Test func theRefusalsNameTheRuntimeAndTheRoute() {
        #expect(OrgAccountWords.requires(runtime: "claude", route: "Acme Bedrock") == "Your organisation requires Claude to use Acme Bedrock.")
        #expect(OrgAccountWords.routeRemoved("Acme Bedrock") == "Your organisation removed Acme Bedrock.")
        #expect(OrgAccountWords.routeExpired(kind: "bedrock")
            == "Your organisation’s Bedrock access ended while this machine is offline. Connect to the network.")
    }

    @Test func anAdminsRouteDecodesWithNoValue() throws {
        let json = #"""
        {"routes":[{"route":{"id":"acme","name":"Acme","kind":"key","vendor":"anthropic","runtimes":["claude"],
          "secretFields":["apiKey"],"fingerprint":{"apiKey":"1a2b3c4d"},"version":2,"machines":3,
          "changed":{"by":{"user":"u","userName":"Priya"},"at":700000000}},"rev":"r1"}],"sealing":true}
        """#
        let list = try JSONDecoder().decode(DaemonAPI.OrgRouteList.self, from: Data(json.utf8))
        #expect(list.routes.first?.route.fingerprint?["apiKey"] == "1a2b3c4d")
        #expect(list.routes.first?.route.machines == 3)
    }
}
