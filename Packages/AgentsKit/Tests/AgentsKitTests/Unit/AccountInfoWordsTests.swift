@testable import AgentsKitCore
import Foundation
import Testing

/// An account's row (#4160): the same words as `Web/src/model/accounts.ts`, held to the same
/// cases in `Web/test/accountInfo.test.mjs`.
struct AccountInfoWordsTests {
    let now = Date(timeIntervalSince1970: 1_794_132_840) // 8 Nov 2026, 10:14 UTC
    let utc = TimeZone(identifier: "UTC")!

    func row(_ name: String, hint: String? = nil, machines: [String] = ["a", "b"], backedUp: Bool? = true) -> DaemonAPI.UserSecretRow {
        var row = DaemonAPI.UserSecretRow(name: name, updated: "2026-10-12T09:14:00Z", machines: machines)
        row.hint = hint
        row.backedUp = backedUp
        return row
    }

    @Test func theHintOfItsSecret() {
        let rows = [row("GITLAB_TOKEN", hint: "ab12"), row("CARD")]
        #expect(AccountsWords.hint(.init(service: "gitlab.com", secret: "GITLAB_TOKEN"), rows: rows) == "••••ab12")
        #expect(AccountsWords.hint(.init(service: "aws.amazon.com", card: "CARD"), rows: rows) == "••••")
        #expect(AccountsWords.hint(.init(service: "slack.com"), rows: rows) == "no secret")
        #expect(AccountsWords.hint(.init(service: "x.com", secret: "ELSEWHERE"), rows: rows) == "not in Secrets")
    }

    @Test func aLineSaysMadeEditedUsedAndExpiry() throws {
        let account = DaemonAPI.OutsideAccount(service: "gitlab.com", made: "2026-10-30", tokenExpires: "2026-12-23",
                                               edited: now.addingTimeInterval(-86_400),
                                               lastOp: .init(what: "read", at: now.addingTimeInterval(-7200)))
        let parts = AccountsWords.line(account, now: now, timeZone: utc)
        #expect(SecretInfoWords.joined(parts) == "Made 9 d ago · Edited 1 d ago · Used 2 h ago · Token expires in 45 d")
        try #require(parts.count == 4)
        #expect(parts[0].help == "Made 2026-10-30")
        #expect(parts[2].help == "Read 8 Nov 2026, 08:14")
    }

    @Test func aNewAccountIsNeverUsed() {
        let account = DaemonAPI.OutsideAccount(service: "slack.com", made: "2026-11-08", tokenExpires: "2026-11-20")
        #expect(SecretInfoWords.joined(AccountsWords.line(account, now: now, timeZone: utc)) == "Made today · Never used")
        let added = AccountsWords.used(.init(what: "added", at: now.addingTimeInterval(-300)), now: now, timeZone: utc)
        #expect(added.text == "Used 5 min ago")
        #expect(added.help == "Added by an agent 8 Nov 2026, 10:09")
    }

    @Test func itsKeyOrCardOnOneMachineIsNotBackedUp() {
        let rows = [row("AWS_SECRET_KEY", machines: ["devbox"], backedUp: false), row("CARD", machines: ["mac"], backedUp: false)]
        let names = ["devbox": "devbox"]
        #expect(AccountsWords.notBackedUp(.init(service: "aws.amazon.com", card: "CARD", secret: "AWS_SECRET_KEY"), rows: rows, names: names)
            == "Its key, AWS_SECRET_KEY, is only on devbox. Not backed up.")
        #expect(AccountsWords.notBackedUp(.init(service: "aws.amazon.com", card: "CARD"), rows: rows, names: names)
            == "Its card, CARD, is only on one machine. Not backed up.")
        #expect(AccountsWords.notBackedUp(.init(service: "gitlab.com", secret: "GONE"), rows: rows) == nil)
        #expect(AccountsWords.notBackedUp(.init(service: "gitlab.com", secret: "OK"), rows: [row("OK")]) == nil)
    }
}
