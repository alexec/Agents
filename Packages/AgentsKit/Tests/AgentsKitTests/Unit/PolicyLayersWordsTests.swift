import Foundation
import Testing
@testable import AgentsKitCore

/// Agents ▸ Policy's words and rows (#2957, T038): the banner, which values a cap dims, and
/// setting a rule on your layer. `Web/test/policyLayers.test.mjs` checks the same on the web.
@Suite("Policy layers words")
struct PolicyLayersWordsTests {
    static func row(_ rule: String) -> PolicyLayersWords.Row {
        PolicyLayersWords.rows.first { $0.rule == rule }!
    }

    @Test func everyRuleOfTheSpecHasARowInOneOfTheFiveSections() {
        let rules = Set(PolicyLayersWords.rows.map(\.rule))
        #expect(rules == ["permissionMode", "permissionRequests", "sandbox", "budgets.perAgent", "budgets.daily",
                          "budgets.perAgentTokens", "budgets.dailyTokens", "helpers.mostRunning", "helpers.mostNotArchived",
                          "workflows.mostOn", "noticeLimits.burst", "noticeLimits.waitMinutes", "archiveMyChats", "runtimes",
                          "marketplaces.allowed", "marketplaces.customServers", "environment"])
        #expect(PolicyLayersWords.Section.allCases.map(\.title) == ["Permissions", "Money", "Work at once", "Your attention", "Tools"])
    }

    @Test func theBannerNamesTheOrganisationOrSaysYouSetEveryLimit() {
        #expect(PolicyLayersWords.banner(.init(organisation: "Acme")) == "Acme sets limits above yours")
        #expect(PolicyLayersWords.banner(.init()) == "You set every limit")
        #expect(PolicyLayersWords.foldersLine(0) == "No folder has its own rules.")
        #expect(PolicyLayersWords.foldersLine(1) == "1 folder has its own rules.")
        #expect(PolicyLayersWords.foldersLine(3) == "3 folders have their own rules.")
    }

    @Test func aCapDimsOnlyTheLooserValues() {
        let mode = Self.row("permissionMode")
        let cap = JSONValue.string("approveForMe")
        #expect(PolicyLayersWords.isLooser(mode, .string("bypassPermissions"), than: cap))
        #expect(!PolicyLayersWords.isLooser(mode, .string("approveForMe"), than: cap))
        #expect(!PolicyLayersWords.isLooser(mode, .string("plan"), than: cap))
        #expect(!PolicyLayersWords.isLooser(mode, .string("bypassPermissions"), than: nil))
        // Fewer is tighter, but a longer wait is.
        #expect(PolicyLayersWords.isLooser(Self.row("helpers.mostRunning"), .int(5), than: .int(3)))
        #expect(PolicyLayersWords.isLooser(Self.row("noticeLimits.waitMinutes"), .int(5), than: .int(10)))
        #expect(!PolicyLayersWords.isLooser(Self.row("noticeLimits.waitMinutes"), .int(30), than: .int(10)))
        #expect(PolicyLayersWords.isLooser(Self.row("budgets.daily"), .object(["amount": .int(50), "currency": .string("USD")]),
                                           than: .object(["amount": .double(40), "currency": .string("USD")])))
        #expect(PolicyLayersWords.isLooser(Self.row("archiveMyChats"), .bool(true), than: .bool(false)))
    }

    @Test func settingARuleKeepsOnlyTheRulesTheLayerSets() {
        var rules = DaemonAPI.PolicyRules()
        rules = PolicyLayersWords.setting(rules, "budgets.daily", to: .object(["amount": .int(40), "currency": .string("USD")]))
        #expect(rules.budgets?.daily == Cost(amount: 40, currency: "USD"))
        #expect(PolicyLayersWords.value(rules, "budgets.daily") == .object(["amount": .double(40), "currency": .string("USD")]))
        rules = PolicyLayersWords.setting(rules, "budgets.daily", to: nil)
        #expect(rules.budgets == nil)
        rules = PolicyLayersWords.setting(rules, "permissionMode", to: .string("ask"))
        #expect(rules.permissionMode == .ask)
        // On is the default, so only Off is kept.
        rules = PolicyLayersWords.setting(rules, "archiveMyChats", to: .bool(true))
        #expect(rules.archiveMyChats == nil)
        rules = PolicyLayersWords.setting(rules, "archiveMyChats", to: .bool(false))
        #expect(rules.archiveMyChats == false)
        rules = PolicyLayersWords.setting(rules, "noticeLimits.waitMinutes", to: .int(30))
        #expect(rules.noticeLimits == DaemonAPI.PolicyNoticeLimits(waitMinutes: 30))
    }

    @Test func choicesSayTheMachinesWords() {
        #expect(PolicyLayersWords.choice("permissionMode", "approveForMe") == "Approve for me")
        #expect(PolicyLayersWords.choice("permissionRequests", "default") == "Ask me")
        #expect(PolicyLayersWords.choice("sandbox", "off") == "Off allowed")
        #expect(PolicyLayersWords.count("noticeLimits.waitMinutes", 120) == "2 hours")
    }

    @Test func yourValueUnderACapIsKept() {
        let rule = DaemonAPI.EffectiveRule(rule: "permissionMode", words: "Approve for me", layers: [
            .init(layer: .init(kind: "organisation", name: "Acme"), value: .string("approveForMe"), words: "Approve for me"),
            .init(layer: .init(kind: "you", name: "You"), value: .string("bypassPermissions"), words: "Bypass Permissions", kept: true),
        ])
        #expect(PolicyLayersWords.yoursIsKept(rule))
        #expect(PolicyLayersWords.layerLine(.init(kind: "folder", name: "payments-api", folder: "/p")) == "payments-api (.agents/policy.json)")
    }

    @Test func anEmptyFieldIsNoLimitAndTextThatIsNoAmountSavesNothing() {
        #expect(PolicyLayersWords.moneyValue("") == .some(nil))
        #expect(PolicyLayersWords.moneyValue("$40") == .some(.object(["amount": .double(40), "currency": .string("USD")])))
        #expect(PolicyLayersWords.moneyValue("forty") == nil)
        #expect(PolicyLayersWords.tokensValue("2,000,000") == .some(.int(2_000_000)))
        #expect(PolicyLayersWords.tokensValue("0") == nil)
        #expect(PolicyLayersWords.amountWords(.object(["amount": .double(40), "currency": .string("USD")])) == "40")
    }
}
