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
        let a = DaemonAPI.OutsideAccount(service: "aws.amazon.com", monthlyCostUsd: 12.5, projects: ["Agents", "Web"])
        #expect(AccountsWords.account(AccountsWords.fields(a)) == a)
        #expect(AccountsWords.account(["service": " x.com ", "plan": " "]) == DaemonAPI.OutsideAccount(service: "x.com"))
    }
}
