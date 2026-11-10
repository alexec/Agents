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
                          "marketplaces.allowed", "marketplaces.customServers", "environment", "connectorTools"])
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

    // MARK: Stopped by a policy (FR-025)

    @Test func theStopCardOffersAChangeOnlyForALayerThePersonEdits() {
        let you = DaemonAPI.PolicyLayerRef(kind: "you", name: "You")
        let folder = DaemonAPI.PolicyLayerRef(kind: "folder", name: "payments-api", folder: "/src/payments-api")
        let org = DaemonAPI.PolicyLayerRef(kind: "organisation", name: "Acme")
        func stop(_ layer: DaemonAPI.PolicyLayerRef, _ reason: String = "policy") -> PolicyLayersWords.StopAction {
            PolicyLayersWords.stopAction(.init(reason: reason, rule: "permissionMode", words: "w", layer: layer))
        }
        #expect(stop(you) == .changeYours)
        #expect(stop(folder) == .changeFolder("/src/payments-api"))
        #expect(stop(org, "budget") == .openSpending)
        #expect(stop(org) == .seeOrganisation)
        #expect(PolicyLayersWords.stopAction(.init(reason: "update", words: "w")) == .seeOrganisation)
        #expect(PolicyLayersWords.stopActionTitle(.changeYours) == "Change in Agents ▸ Policy")
        #expect(PolicyLayersWords.stopActionTitle(.changeFolder("/x")) == "Change in Project Settings ▸ Policy")
    }

    @Test func onlyTheOrganisationsBudgetOffersAskForMore() {
        func refusal(_ kind: String, _ reason: String) -> DaemonAPI.PolicyRefusal {
            .init(reason: reason, rule: "budgets.daily", words: "w", layer: .init(kind: kind, name: "Acme"))
        }
        #expect(PolicyLayersWords.canAskForMore(refusal("organisation", "budget")))
        #expect(!PolicyLayersWords.canAskForMore(refusal("you", "budget")))
        #expect(!PolicyLayersWords.canAskForMore(refusal("organisation", "policy")))
        #expect(PolicyLayersWords.canAskForMore(.init(reason: "budget", words: "w")))
    }

    @Test func theStopCardSaysWhereAnAskStands() {
        var r = DaemonAPI.BudgetRequest(id: "r", user: "u", userName: "Sam", day: "2026-11-03", at: Date())
        #expect(PolicyLayersWords.asked(r) == "Asked. An admin can raise today's budget.")
        r.state = .raised
        r.daily = 80
        r.decidedBy = "Alex"
        #expect(PolicyLayersWords.asked(r) == "Raised to $80 for today by Alex. Send again to go on.")
        r.state = .refused
        #expect(PolicyLayersWords.asked(r) == "Refused for today by Alex.")
        let old = JSONRPCError(code: JSONRPCError.methodNotFound, message: "no")
        #expect(PolicyLayersWords.askRefusal(old).hasPrefix("This control plane cannot take the request yet."))
    }

    @Test func theStopCardNamesTheRuleAndTheLayersValue() {
        #expect(PolicyLayersWords.ruleTitle("budgets.daily") == "Per day")
        #expect(PolicyLayersWords.ruleTitle("budgets") == "Budget")
        let r = DaemonAPI.PolicyRefusal(reason: "budget", rule: "budgets.daily", words: "What you sent is waiting.",
                                        layer: .init(kind: "you", name: "You"), value: "at most $1.00 a day")
        #expect(PolicyLayersWords.stopLine(r) == "Your policy: at most $1.00 a day")
        var same = r
        same.value = same.words
        #expect(PolicyLayersWords.stopLine(same) == nil)
    }

    @Test func aFolderRowStartsAtSameAsYours() {
        #expect(PolicyLayersWords.sameAsYours("Ask") == "Same as yours (Ask)")
        let rule = DaemonAPI.EffectiveRule(rule: "permissionMode", value: .string("ask"), words: "Ask",
                                           layers: [.init(layer: .init(kind: "you", name: "You"), value: .string("ask"), words: "Ask"),
                                                    .init(layer: .init(kind: "folder", name: "f"), value: .string("bypassPermissions"),
                                                          words: "Bypass Permissions", kept: true)])
        #expect(PolicyLayersWords.folderIsCapped(rule))
        #expect(!PolicyLayersWords.yoursIsKept(rule))
    }

    @Test func aWaitingPolicyChangeSaysWhatItKeeps() {
        #expect(GuardedChange.Policy(looser: ["permissionMode"], words: "Permission mode: Ask → Bypass Permissions", was: "Ask")
            .keepTitle == "Keep Ask")
        #expect(GuardedChange.Policy(looser: ["permissionMode", "sandbox"], words: "…").keepTitle == "Keep Old Rules")
    }

    @Test func aPolicyStopIsReadAndWrittenAsTheWireHasIt() throws {
        let raw = #"{"policyStopped":{"_0":{"reason":"budget","rule":"budgets.daily","words":"w","layer":{"kind":"you","name":"You"},"value":"v"}}}"#
        let kind = try JSONDecoder().decode(TranscriptEntry.Kind.self, from: Data(raw.utf8))
        guard case .policyStopped(let refusal) = kind else {
            Issue.record("read as \(kind)")
            return
        }
        #expect(refusal.layer?.kind == "you" && refusal.value == "v")
        let again = try JSONDecoder().decode(TranscriptEntry.Kind.self, from: JSONEncoder().encode(kind))
        #expect(again == kind)
    }

    /// Rules signed on another Mac (#3230): the same words as the web page's, read as the wire has them.
    @Test func rulesSignedOnAnotherMacSaySoAndOfferToSignAgain() throws {
        let raw = #"{"policy":{"rules":{},"revision":0,"changed":0,"person":"local","keeper":"h"},"keeper":{"host":"h","name":"h"},"untrusted":{"file":"policy-yours.json","rules":{"budgets":{"daily":{"amount":40,"currency":"USD"}}},"revision":2,"changed":815227200,"keeper":"h","keyID":"k","lines":[{"rule":"budgets.daily","title":"Per day","words":"$40.00 a day"}]}}"#
        let state = try JSONDecoder().decode(DaemonAPI.YourPolicyState.self, from: Data(raw.utf8))
        let copy = try #require(state.untrusted)
        #expect(PolicyLayersWords.untrustedLine(copy).hasPrefix("These rules were signed on another Mac on "))
        let line = try #require(copy.lines.first)
        #expect(PolicyLayersWords.untrustedRule(line) == "Per day: $40.00 a day")
        #expect(PolicyLayersWords.signAgain == "Sign with This Mac’s Key")
        #expect(PolicyLayersWords.setAside == "Don’t Use Them")
    }
}
