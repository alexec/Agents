@testable import AgentsKitCore
import Foundation
import Testing

/// A secret's row (#4159): the same words as `Web/src/model/secretInfo.ts`, held to the same
/// cases in `Web/test/secretInfo.test.mjs`.
struct SecretInfoWordsTests {
    let now = Date(timeIntervalSince1970: 1_794_132_840)
    let utc = TimeZone(identifier: "UTC")!

    @Test func theLast4OrDotsOnly() {
        #expect(SecretInfoWords.hint("ab12") == "••••ab12")
        #expect(SecretInfoWords.hint(nil) == "••••")
    }

    @Test func anAgeIsShort() {
        #expect(SecretInfoWords.age(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(SecretInfoWords.age(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(SecretInfoWords.age(now.addingTimeInterval(-7200), now: now) == "2 h ago")
        #expect(SecretInfoWords.age(now.addingTimeInterval(-27 * 86_400), now: now) == "27 d ago")
        #expect(SecretInfoWords.stamp(Date(timeIntervalSince1970: 1_791_796_440), timeZone: utc) == "12 Oct 2026, 09:14")
    }

    @Test func aRowSaysWhereWhenAddedAndWhenUsed() throws {
        var row = DaemonAPI.UserSecretRow(name: "GITHUB_TOKEN", updated: "2026-10-12T09:14:00Z", machines: ["a", "b", "c"])
        row.created = "2026-10-12T09:14:00.123Z"
        row.lastOp = .init(what: "read", at: now.addingTimeInterval(-7200))
        let parts = SecretInfoWords.line(row, now: now, timeZone: utc)
        try #require(parts.count == 3)
        #expect(SecretInfoWords.joined(parts) == "On 3 machines · Added 27 d ago · Used 2 h ago")
        #expect(parts[1].help == "Added 12 Oct 2026, 09:14")
        #expect(parts[2].help?.hasPrefix("Read ") == true)

        row.updated = "2026-11-06T09:14:00Z"
        row.lastOp = .init(what: "replaced", at: now.addingTimeInterval(-86_400))
        #expect(SecretInfoWords.joined(SecretInfoWords.line(row, now: now, timeZone: utc))
            == "On 3 machines · Replaced 2 d ago · Not used since it was replaced")
        let replaced = SecretInfoWords.line(row, now: now, timeZone: utc)
        try #require(replaced.count == 3)
        #expect(replaced[1].help == "Added 12 Oct 2026, 09:14\nReplaced 6 Nov 2026, 09:14")

        row.created = nil
        row.lastOp = nil
        #expect(SecretInfoWords.joined(SecretInfoWords.line(row, now: now, timeZone: utc)) == "On 3 machines · Set 2 d ago · Never used")
        row.lastOp = .init(what: "added", at: now)
        #expect(SecretInfoWords.used(row.lastOp, now: now).text == "Never used")
        row.lastOp = .init(what: "denied", at: now.addingTimeInterval(-300))
        #expect(SecretInfoWords.used(row.lastOp, now: now).text == "Use denied 5 min ago")
    }

    @Test func oneCopyIsNotBackedUp() {
        var row = DaemonAPI.UserSecretRow(name: "OPENAI_API_KEY", updated: "", machines: ["box"])
        row.backedUp = false
        #expect(SecretInfoWords.notBackedUp(row, names: ["box": "devbox"])
            == "Only on devbox. Not backed up: if devbox is lost, this secret is lost.")
        #expect(SecretInfoWords.notBackedUp(row) == "Only on one machine. Not backed up: if it is lost, this secret is lost.")
        row.waiting = ["mac"]
        #expect(SecretInfoWords.notBackedUp(row) == nil)
        row.waiting = nil
        row.backedUp = true
        #expect(SecretInfoWords.notBackedUp(row) == nil)
    }

    @Test func aPersonWithOneMachineIsToldOnce() {
        var only = DaemonAPI.UserSecretRow(name: "A", updated: "", machines: ["mac"])
        only.backedUp = false
        #expect(SecretInfoWords.onlyMachine([only, only]) == "mac")
        #expect(SecretInfoWords.names([], thisMac: .mac) == ["mac": "this Mac"])
        #expect(SecretInfoWords.onlyMachineLine("mac", names: ["mac": "this Mac"])
            == "Your secrets are only on this Mac. Add a second machine to keep a copy.")
        var two = DaemonAPI.UserSecretRow(name: "B", updated: "", machines: ["mac", "box"])
        two.backedUp = true
        #expect(SecretInfoWords.onlyMachine([only, two]) == nil)
        #expect(SecretInfoWords.onlyMachine([two]) == nil)
    }

    @Test func aSessionsSecretSaysItsSession() {
        let secret = SessionSecret(agentID: UUID(), title: "Fix the shop sign-in", name: "SHOP_PASSWORD",
                                   setAt: now.addingTimeInterval(-3600), created: now.addingTimeInterval(-3600),
                                   lastOp: .init(what: "read", at: now.addingTimeInterval(-1200)), backedUp: false)
        #expect(SecretInfoWords.joined(SecretInfoWords.line(secret, now: now)) == "Fix the shop sign-in · Added 1 h ago · Used 20 min ago")
    }

    /// #5122: a secret an agent saved on the machine says when it was set and used.
    @Test func aMachinesOwnSecretSaysWhenSetAndUsed() {
        let secret = LocalSecret(name: "GITHUB_SAM_TOKEN", setAt: now.addingTimeInterval(-3600),
                                 lastOp: .init(what: "read", at: now.addingTimeInterval(-1200)), backedUp: false, needsApproval: true)
        #expect(SecretInfoWords.joined(SecretInfoWords.line(secret, now: now)) == "Set 1 h ago · Used 20 min ago")
        #expect(secret.asksBeforeUse)
        #expect(LocalSecretWords.header == "On This Machine")
    }
}
