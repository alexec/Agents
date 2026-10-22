import Foundation
import Testing
@testable import AgentsKitCore

/// Several accounts per runtime (#840): an added account is its own row, says who it is,
/// and does not put the runtime itself in the out run.
@Suite("An account added to a runtime")
struct AccountProfileTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func row(_ key: String, out: Bool = false, account: String? = nil) -> RuntimeAllowances.Row {
        var state = AllowanceState(credentialKey: key, entryID: UUID(), since: now)
        if out { state.markOut(.allowanceSpent, until: nil, payment: .allowance(label: nil), now: now, from: .typedFailure) }
        return RuntimeAllowances.Row(credentialKey: key, state: state, accountID: account.map { _ in "w1" }, accountName: account)
    }

    @Test func anAddedAccountOutLeavesTheRuntimeAvailable() {
        let allowances = RuntimeAllowances(rows: [row("claude:sign-in"), row("claude:account:w1", out: true, account: "Work")], at: now)
        #expect(!allowances.isOut("claude"))
        #expect(allowances.startingOnOut("claude") == nil)
        #expect(allowances.row("claude", account: "w1")?.state.isOut == true)
        #expect(allowances.row("claude", account: nil)?.credentialKey == "claude:sign-in")
    }

    @Test func itsRowIsNamedForTheRuntimeAndTheAccount() {
        #expect(row("claude:account:w1", account: "Work").title == "Claude · Work")
        #expect(row("claude:sign-in").title == "Claude")
    }

    @Test func itReadsAsTheHostWritesIt() throws {
        let json = #"{"id":"w1","runtimeID":"claude","name":"Work","reach":{"signIn":{"folder":"/r/a"}},"addedAt":0,"signedIn":true,"signedInAs":"a@example.com"}"#
        let p = try JSONDecoder().decode(AccountProfile.self, from: Data(json.utf8))
        #expect(p.reach == .signIn(folder: "/r/a"))
        #expect(p.state == "Signed in as a@example.com")
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any]
        #expect((back?["reach"] as? [String: Any])?["signIn"] as? [String: String] == ["folder": "/r/a"])
    }

    /// An org route on a machine (#999): an org key and a gateway decode as theirs, with who
    /// gave them, the default and the policy's mark; a way a newer host names is kept whole.
    @Test func orgAccountsAndLaterWaysDecode() throws {
        let json = #"""
        [{"id":"org:acme","runtimeID":"claude","name":"Acme Gateway","reach":{"gateway":{"route":"acme","kind":"baseURL"}},
          "source":"organisation","isDefault":true,"addedAt":0,"signedIn":true},
         {"id":"org:key","runtimeID":"codex","name":"Acme Key","reach":{"orgKey":{"route":"key"}},"source":"organisation","addedAt":0,"signedIn":true},
         {"id":"w1","runtimeID":"claude","name":"Work","reach":{"signIn":{"folder":"/r/a"}},"addedAt":0,"signedIn":false,
          "setBy":{"by":"organisation","rule":"runtimes.claude.reach","words":"Your organisation requires Claude to use Acme Gateway."}},
         {"id":"x","runtimeID":"claude","name":"Later","reach":{"teleport":{}},"addedAt":0,"signedIn":true}]
        """#
        let list = try JSONDecoder().decode([AccountProfile].self, from: Data(json.utf8))
        try #require(list.map(\.name) == ["Acme Gateway", "Acme Key", "Work", "Later"])
        let gateway = list[0], key = list[1], work = list[2], later = list[3]  // index-ok: the four names are required just above
        #expect(gateway.reach == .gateway(route: "acme", kind: "baseURL"))
        #expect(gateway.isOrganisation && gateway.isDefault == true)
        #expect(gateway.state == "From your organisation")
        #expect(key.reach == .orgKey(route: "key") && key.reach.route == "key")
        #expect(work.reach == .signIn(folder: "/r/a") && !work.isOrganisation)
        #expect(work.setBy?.rule == "runtimes.claude.reach")
        #expect(later.reach == .other(["teleport": [:]]))
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gateway)) as? [String: Any]
        #expect(((back?["reach"] as? [String: Any])?["gateway"] as? [String: String]) == ["route": "acme", "kind": "baseURL"])
        let kept = try JSONSerialization.jsonObject(with: JSONEncoder().encode(later)) as? [String: Any]
        #expect((kept?["reach"] as? [String: Any])?["teleport"] != nil)
    }

    @Test func anAccountNotSignedInSaysSo() {
        let p = AccountProfile(id: "w1", runtimeID: "codex", name: "Work", reach: .signIn(folder: "/r/a"))
        #expect(p.state == "Not signed in")
    }

    /// A started session names the account it runs on (#2259), never the runtime's own.
    @Test func aSessionsAccountIsNamedByItsID() {
        let accounts = [AccountProfile(id: "w1", runtimeID: "claude", name: "Work", reach: .signIn(folder: "/a")),
                        AccountProfile(id: "w2", runtimeID: "codex", name: "Home", reach: .signIn(folder: "/b"))]
        #expect(accounts.name(of: "w1", on: "claude") == "Work")
        #expect(accounts.name(of: "w2", on: "claude") == nil, "another runtime's")
        #expect(accounts.name(of: nil, on: "claude") == nil)
        #expect(accounts.name(of: AccountProfile.ownSignInID, on: "claude") == nil)
        #expect(accounts.name(of: "gone", on: "claude") == nil)
    }
}
