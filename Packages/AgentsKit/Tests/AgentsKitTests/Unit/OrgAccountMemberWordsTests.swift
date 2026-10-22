import Foundation
import Testing
@testable import AgentsKitCore

/// An org account as a member sees it (#999, slice 3): its allowance line, with no plan
/// reading, its tokens today and "Out until …"; the cost note; the runtime's default.
/// `Web/test/runtimes.test.mjs` checks the same words on the web page.
@Suite("Org account, as a member sees it")
struct OrgAccountMemberWordsTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ key: String, account: String?, tokens: Int? = nil, limitedFor: TimeInterval? = nil) -> RuntimeAllowances.Row {
        var state = AllowanceState(credentialKey: key, entryID: UUID(), since: now)
        if let limitedFor { state.status = .rateLimited(until: now.addingTimeInterval(limitedFor)) }
        return RuntimeAllowances.Row(credentialKey: key, state: state, accountID: account, accountName: "Acme Bedrock",
                                     tokensToday: tokens)
    }

    @Test func anOrgAccountHasNoPlanLimitAndSaysItsTokens() {
        let org = row("claude:account:org:acme", account: "org:acme", tokens: 12_000)
        #expect(org.isOrganisation)
        #expect(org.memberLine(now: now) == "Organisation · No plan limit · 12,000 tokens today")
        #expect(row("claude:account:org:acme", account: "org:acme").memberLine(now: now) == "Organisation · No plan limit")
    }

    @Test func aRateLimitedOrgAccountIsOutUntilItsTime() {
        let out = row("claude:account:org:acme", account: "org:acme", tokens: 5, limitedFor: 600)
        let clock = PoolWords.time(now.addingTimeInterval(600), now: now)
        #expect(out.memberLine(now: now) == "Out until \(clock) · 5 tokens today")
    }

    @Test func anAddedAccountKeepsThePoolLine() {
        let work = row("claude:account:w1", account: "w1")
        #expect(!work.isOrganisation)
        #expect(work.memberLine(now: now) == work.line(now: now))
    }

    @Test func aReportedCostSaysWhosePrice() {
        #expect(OrgAccountWords.listPrice("claude") == "list price, as Claude reports it")
    }

    @Test func theDefaultIsTheAccountThatSaysSo() {
        let list = [
            AccountProfile(id: "w1", runtimeID: "claude", name: "Work", reach: .signIn(folder: "/a")),
            AccountProfile(id: "org:acme", runtimeID: "claude", name: "Acme", reach: .orgKey(route: "acme"),
                           signedIn: true, source: "organisation", isDefault: true),
        ]
        #expect(list.defaultAccount("claude")?.id == "org:acme")
        #expect(list.defaultAccount("codex") == nil)
        #expect(list.added(to: "claude").map(\.id) == ["w1"])
        #expect(list.organisation("claude").map(\.id) == ["org:acme"])
    }

    @Test func aSessionWhoseAccountIsGoneOrRefusedIsToldToMove() {
        let refused = DaemonAPI.PolicySetBy(rule: "runtimes.claude.reach", words: "Your organisation requires Claude to use Acme.")
        let list = [
            AccountProfile(id: "w1", runtimeID: "claude", name: "Work", reach: .signIn(folder: "/a"), setBy: refused),
            AccountProfile(id: "org:acme", runtimeID: "claude", name: "Acme", reach: .orgKey(route: "acme"),
                           signedIn: true, source: "organisation", isDefault: true),
        ]
        let policy = DaemonAPI.OrgPolicy(version: 1, issued: now, changedBy: .init(user: "u"),
                                         runtimes: ["claude": DaemonAPI.PolicyRuntimeRule(reach: ["orgKey", "gateway"])])
        let choices = AccountChoices(runtimeID: "claude", profiles: list, policy: policy)
        #expect(choices.moveReason(accountID: "w1", loaded: true) == refused.words)
        #expect(choices.moveReason(accountID: nil, loaded: true) == "Your organisation requires Claude to use Acme.")
        #expect(choices.moveReason(accountID: "org:gone", loaded: true) == "Your organisation removed this way to the model.")
        #expect(choices.moveReason(accountID: "org:acme", loaded: true) == nil)
        #expect(choices.moveReason(accountID: "org:gone", loaded: false) == nil)
        // The picker: nil is the default, the own sign-in is "default" while an account is the default.
        #expect(choices.name(nil) == "Acme" && choices.ownChoice == "default" && choices.sent("default") == "default")
        #expect(choices.sent("nope") == nil && choices.account(for: "default") == nil)
        #expect(AccountChoices(runtimeID: "codex", profiles: list).ownChoice == nil)
    }
}
