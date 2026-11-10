import Foundation
import Testing
@testable import AgentsKitCore

/// Settings ▸ You ▸ Accounts (#3967): the project filter, the foot and the token mark.
struct AccountsWordsTests {
    let all = [
        DaemonAPI.OutsideAccount(service: "gitlab.com", monthlyCostUsd: 0),
        DaemonAPI.OutsideAccount(service: "aws.amazon.com", monthlyCostUsd: 12.5, projects: ["Agents"]),
        DaemonAPI.OutsideAccount(service: "slack.com", monthlyCostUsd: 8, projects: ["Other"]),
    ]

    @Test func anAccountWithNoProjectsIsForAll() {
        #expect(AccountsWords.of(all, project: "agents").map(\.service) == ["gitlab.com", "aws.amazon.com"])
        #expect(AccountsWords.of(all, project: "").count == 3)
        #expect(AccountsWords.projects(all) == ["Agents", "Other"])
    }

    /// #4190: only a control plane that says user/3 takes the accounts part.
    @Test func anOlderControlPlaneIsSentNoAccounts() {
        var status = DaemonAPI.ControlStatus(name: "c", version: "0.17.0", homeHost: nil, machineID: "m")
        #expect(AccountsWords.refusal(nil) == nil)
        #expect(AccountsWords.refusal(status) == "The control plane needs an update to do this.")
        status.capabilities = [Capability.user1, Capability.user2]
        #expect(AccountsWords.refusal(status) == AccountsWords.planeNeedsUpdate)
        status.capabilities?.append(Capability.user3)
        #expect(AccountsWords.refusal(status) == nil)
    }

    @Test func theFootAddsUpTheCost() {
        #expect(AccountsWords.foot(all) == "3 accounts, $20.50 a month.")
        #expect(AccountsWords.foot([]) == "0 accounts, $0 a month.")
    }

    @Test func aTokenThatExpiresSoonIsMarked() {
        let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!
        var a = DaemonAPI.OutsideAccount(service: "x", tokenExpires: "2026-11-20")
        #expect(AccountsWords.expiresSoon(a, now: now) == "Its token expires on 2026-11-20.")
        a.tokenExpires = "2027-10-18"
        #expect(AccountsWords.expiresSoon(a, now: now) == nil)
        a.tokenExpires = "2026-11-01"
        #expect(AccountsWords.expiresSoon(a, now: now) == "Its token expired on 2026-11-01.")
    }

    @Test func theSheetsFieldsGoBothWays() {
        let a = DaemonAPI.OutsideAccount(service: "aws.amazon.com", description: "The agents' own AWS account.", monthlyCostUsd: 12.5,
                                         projects: ["Agents", "Web"])
        #expect(AccountsWords.account(AccountsWords.fields(a)) == a)
        #expect(AccountsWords.account(["service": " x.com ", "plan": " "]) == DaemonAPI.OutsideAccount(service: "x.com"))
    }

    /// Ask before use (#4163): nil is on, and the sheet keeps it off when it is off.
    @Test func askBeforeUseIsOnAtFirst() {
        #expect(AccountsWords.asks(DaemonAPI.OutsideAccount(service: "x")))
        let off = DaemonAPI.OutsideAccount(service: "x", askBeforeUse: false)
        #expect(!AccountsWords.asks(off))
        #expect(AccountsWords.account(AccountsWords.fields(off)) == off)
        #expect(AccountsWords.account(["service": "x"]).askBeforeUse == nil)
    }

    /// An account made before descriptions (#4164) says so.
    @Test func anAccountWithNoDescriptionSaysSo() {
        #expect(AccountsWords.about(all[0]) == "No description")
        #expect(AccountsWords.about(DaemonAPI.OutsideAccount(service: "x", description: " For tests. ")) == "For tests.")
    }
}
