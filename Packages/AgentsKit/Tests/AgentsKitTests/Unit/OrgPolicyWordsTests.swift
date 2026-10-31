import Foundation
import Testing
@testable import AgentsKitCore

/// The organisation's policy as the window and the Remote read it (#998, T029): the rules in
/// words, the kill switch's words, and the `setBy` mark and `policyRefused` error decoded.
/// `Web/test/orgPolicy.test.mjs` checks the same words on the web page.
@Suite("Org policy words")
struct OrgPolicyWordsTests {
    static let priya = DaemonAPI.AuditActor(user: "u-priya", userName: "Priya")

    static func policy(_ edit: (inout DaemonAPI.OrgPolicy) -> Void = { _ in }) -> DaemonAPI.OrgPolicy {
        var p = DaemonAPI.OrgPolicy(version: 4, issued: Date(timeIntervalSince1970: 1_700_000_000), changedBy: priya,
                                    requires: ["host.policy/1"])
        edit(&p)
        return p
    }

    @Test func aPolicyWithNoRulesSaysNone() {
        #expect(OrgPolicyWords.rules(Self.policy()).isEmpty)
    }

    @Test func eachRuleSetIsSaidInItsOrder() {
        let p = Self.policy {
            $0.modeCeiling = "acceptEdits"
            $0.sandbox = "required"
            $0.runtimes = ["codex": .init(), "claude": .init(models: ["claude-sonnet-*"])]
            $0.marketplaces = .init(allowed: ["acme", "github"], customServers: "refuse")
            $0.budgets = .init(daily: 40, dailyTokens: 50_000, perAgent: 2.5, allowUnmetered: ["cursor"])
            $0.helpers = .init(mostRunning: 3, mostNotArchived: 10)
            $0.environment = .init(passThrough: ["OPENAI_*", "ANTHROPIC_*"])
            $0.notices = .init(antigravityTerms: "refuse")
            $0.requireFollowing = true
        }
        let rules = OrgPolicyWords.rules(p)
        #expect(rules.map(\.title) == ["Modes", "Command sandbox", "Runtimes", "Marketplaces", "MCP servers added by hand",
                                       "Budget", "Unmetered runtimes", "Helper sessions", "Variables passed to runtimes",
                                       "Antigravity’s terms", "Machines"])
        #expect(rules.map(\.words) == [
            "Up to Accept Edits", "Required", "Only Claude (claude-sonnet-*), Codex", "Only acme, github", "Not allowed",
            "$40 a day, 50,000 tokens a day, $2.50 an agent", "Allowed: Cursor", "At most 3 running and 10 not archived in a folder",
            "Only ANTHROPIC_*, OPENAI_*", "Antigravity is not allowed",
            "A machine that does not follow this policy starts no agent",
        ])
    }

    @Test func emptyListsAllowNothing() {
        let p = Self.policy {
            $0.runtimes = [:]
            $0.environment = .init(passThrough: [])
            $0.budgets = .init()
        }
        let words = Dictionary(uniqueKeysWithValues: OrgPolicyWords.rules(p).map { ($0.name, $0.words) })
        #expect(words["runtimes"] == "None")
        #expect(words["environment.passThrough"] == "None")
        // A budget with no number is no rule.
        #expect(words["budgets"] == nil)
    }

    @Test func theKillSwitchNamesHowManyAgentsRun() {
        #expect(OrgPolicyWords.stopMessage(running: 3).hasPrefix("This stops the 3 agents running now,"))
        #expect(OrgPolicyWords.stopMessage(running: 1).hasPrefix("This stops the 1 agent running now,"))
        #expect(OrgPolicyWords.stopMessage(running: 0).hasPrefix("No agent is running now."))
        #expect(OrgPolicyWords.stopMessage(running: nil).hasPrefix("This stops every agent running now on every machine,"))
    }

    @Test func theLastChangeNamesWhoAndWhen() {
        let p = Self.policy()
        let sameDay = p.issued.addingTimeInterval(60)
        #expect(OrgPolicyWords.changed(p, now: sameDay).hasPrefix("Version 4, changed by Priya at "))
        #expect(OrgPolicyWords.changed(p, now: p.issued.addingTimeInterval(3 * 86_400)).contains(" on "))
        #expect(OrgPolicyWords.name(DaemonAPI.AuditActor(user: "u-sam")) == "u-sam")
    }

    @Test func theMarkDecodesAndSaysTheLine() throws {
        let json = #"{"by":"organisation","rule":"modeCeiling","words":"Your organisation allows modes up to Accept Edits."}"#
        let mark = try JSONDecoder().decode(DaemonAPI.PolicySetBy.self, from: Data(json.utf8))
        #expect(OrgPolicyWords.line(mark) == "Set by your organisation. Your organisation allows modes up to Accept Edits.")
    }

    @Test func aPolicyRefusalIsReadFromItsError() {
        let error = JSONRPCError(code: -32076, message: "Set by your organisation. Your organisation does not allow Gemini.",
                                 data: ["reason": "policy", "rule": "runtimes", "words": "Your organisation does not allow Gemini."])
        let refusal = DaemonAPI.PolicyRefusal(error: error)
        #expect(refusal?.rule == "runtimes")
        #expect(refusal?.line == "Set by your organisation. Your organisation does not allow Gemini.")
        // noPolicy and mustJoin say what to do, with no title.
        let lost = JSONRPCError(code: -32076, message: "x",
                                data: ["reason": "noPolicy", "words": "Agents Host has no policy from your organisation. Connect to the network."])
        #expect(DaemonAPI.PolicyRefusal(error: lost)?.line == "Agents Host has no policy from your organisation. Connect to the network.")
        #expect(DaemonAPI.PolicyRefusal(error: JSONRPCError(code: -32602, message: "no")) == nil)
    }

    @Test func aPolicyViewDecodesWhatTheControlPlaneSends() throws {
        let json = #"""
        {"policy":{"version":2,"issued":700000000,"changedBy":{"user":"u-priya","userName":"Priya"},"requires":["host.policy/1"],
         "modeCeiling":"auto","groups":{},"stopAll":{"on":true,"by":{"user":"u-priya"},"at":700000100},
         "budgets":{"daily":10,"allowUnmetered":[],"raises":[]}}}
        """#
        let view = try JSONDecoder().decode(DaemonAPI.PolicyView.self, from: Data(json.utf8))
        #expect(view.policy?.isStopped == true)
        #expect(view.policy?.modeCeiling == "auto")
        #expect(DaemonAPI.PolicyView(policy: nil).policy == nil)
    }

    // MARK: Slice 2b: the marks each client draws (T030–T034)

    @Test func theMarksOnEachListDecode() throws {
        let mark = #"{"by":"organisation","rule":"modeCeiling","words":"Your organisation allows modes up to Accept Edits."}"#
        // A mode above the ceiling, in the option's own JSON, flat or in a group.
        let option = try JSONDecoder().decode(ConfigOption.self, from: Data(#"""
        {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"default",
         "options":[{"value":"default","name":"Default"},{"value":"bypassPermissions","name":"Bypass Permissions","setBy":\#(mark)}]}
        """#.utf8))
        #expect(option.options?.map { $0.setBy?.rule } == [nil, "modeCeiling"])
        // A runtime not allowed here: listed, cannot start, and says why.
        var status = RuntimeStatus(runtime: RuntimeCatalog.claude, availability: .available(path: "/bin/claude", supportsResume: true))
        #expect(status.canStart)
        status.setBy = .init(rule: "runtimes", words: "Your organisation does not allow Claude.")
        #expect(!status.canStart)
        #expect(status.unavailableReason == "Set by your organisation. Your organisation does not allow Claude.")
        // The sandbox, cost and a folder's helper limits.
        let sandbox = try JSONDecoder().decode(SandboxSettings.self, from: Data(#"{"defaults":{},"setBy":\#(mark)}"#.utf8))
        #expect(sandbox.setBy?.rule == "modeCeiling")
        let cost = try JSONDecoder().decode(DaemonAPI.CostState.self, from: Data(#"""
        {"limits":{},"today":{},"day":"2026-10-22","tokensToday":0,
         "organisation":{"daily":{"amount":40,"currency":"USD"},"dailyTokens":50000},"setBy":\#(mark)}
        """#.utf8))
        #expect(OrgPolicyWords.budgetRows(cost.organisation).map(\.title) == ["Per day", "Tokens per day"])
        #expect(OrgPolicyWords.budgetRows(cost.organisation).last?.words == "50,000 tokens")
        #expect(OrgPolicyWords.budgetRows(nil).isEmpty)
        #expect(cost.setBy != nil)
    }

    @Test func thePolicyStateSaysWhyTheComposerCannotSend() throws {
        #expect(DaemonAPI.PolicyState().composerReason == nil)
        #expect(!DaemonAPI.PolicyState().startsNothing)
        let stopped = try JSONDecoder().decode(DaemonAPI.PolicyState.self, from: Data(#"""
        {"version":3,"stopAll":true,"noPolicy":false,
         "refusal":{"reason":"stopAll","rule":"stopAll","words":"Your organisation has stopped all agent work."}}
        """#.utf8))
        #expect(stopped.startsNothing)
        #expect(stopped.composerReason == "Set by your organisation. Your organisation has stopped all agent work.")
        let lost = DaemonAPI.PolicyState(noPolicy: true, refusal: .init(reason: "noPolicy",
            words: "Agents Host has no policy from your organisation. Connect to the network."))
        #expect(lost.composerReason == "Agents Host has no policy from your organisation. Connect to the network.")
    }

    @Test func addByHandAndPassThroughNamesAreMarked() throws {
        #expect(OrgPolicyWords.customServersMark(Self.policy()) == nil)
        let refused = Self.policy { $0.marketplaces = .init(allowed: [], customServers: "refuse") }
        #expect(OrgPolicyWords.customServersMark(refused)?.rule == "marketplaces.customServers")
        let state = try JSONDecoder().decode(DaemonAPI.PassThroughState.self, from: Data(#"""
        {"names":[{"name":"AWS_*"},{"name":"OPENAI_API_KEY","runtime":"codex",
          "setBy":{"by":"organisation","rule":"environment.passThrough","words":"Not passed."}},{"name":"GEMINI_KEY","runtime":"gemini"}]}
        """#.utf8))
        #expect(state.names(for: "codex").map(\.name) == ["AWS_*", "OPENAI_API_KEY"])
        #expect(state.names(for: "codex").last?.setBy != nil)
    }
}
