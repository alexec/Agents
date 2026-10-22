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

    /// An org route reaches a machine before this client draws org accounts (#999): the list
    /// still decodes, and the way is kept whole, as the host wrote it.
    @Test func aWayThisBuildDoesNotDrawStillDecodes() throws {
        let json = #"""
        [{"id":"org:acme","runtimeID":"claude","name":"Acme Gateway","reach":{"gateway":{"route":"acme","kind":"baseURL"}},
          "source":"organisation","addedAt":0,"signedIn":true},
         {"id":"w1","runtimeID":"claude","name":"Work","reach":{"signIn":{"folder":"/r/a"}},"addedAt":0,"signedIn":false},
         {"id":"x","runtimeID":"claude","name":"Later","reach":{"teleport":{}},"addedAt":0,"signedIn":true}]
        """#
        let list = try JSONDecoder().decode([AccountProfile].self, from: Data(json.utf8))
        #expect(list.map(\.name) == ["Acme Gateway", "Work", "Later"])
        #expect(list[0].reach == .other(["gateway": ["route": "acme", "kind": "baseURL"]]))
        #expect(list[1].reach == .signIn(folder: "/r/a"))
        let back = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list[0])) as? [String: Any]
        #expect(((back?["reach"] as? [String: Any])?["gateway"] as? [String: String]) == ["route": "acme", "kind": "baseURL"])
    }

    @Test func anAccountNotSignedInSaysSo() {
        let p = AccountProfile(id: "w1", runtimeID: "codex", name: "Work", reach: .signIn(folder: "/r/a"))
        #expect(p.state == "Not signed in")
    }
}
