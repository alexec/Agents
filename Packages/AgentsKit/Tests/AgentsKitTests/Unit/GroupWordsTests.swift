@testable import AgentsKitCore
import Foundation
import Testing

/// Settings ▸ Groups' words (#1761), as the web page's `groups.ts` says them.
@Suite("Group words")
struct GroupWordsTests {
    let sam = DaemonAPI.PersonRow(id: "sam", name: "Sam", role: .member)
    let kim = DaemonAPI.PersonRow(id: "kim", name: "Kim", role: .member)

    @Test func membersAreEveryoneOrNamed() {
        #expect(GroupWords.members(DaemonAPI.Group(id: "g", name: "All", everyone: true), people: [sam]) == "Everyone")
        #expect(GroupWords.members(DaemonAPI.Group(id: "g", name: "P", members: ["sam", "kim"]), people: [sam, kim])
            == "Sam, Kim")
        #expect(GroupWords.members(DaemonAPI.Group(id: "g", name: "P", members: ["gone"]), people: [sam])
            == "Someone removed")
        #expect(GroupWords.members(DaemonAPI.Group(id: "g", name: "P"), people: []) == "No one")
    }

    @Test func aProviderIsForItsGroupOrTheAdmins() {
        let platform = DaemonAPI.Group(id: "g1", name: "Platform", members: ["sam"])
        let given = DaemonAPI.ProviderSummary(id: ProviderID(rawValue: "do"), name: "DigitalOcean", kind: "commands",
                                              group: "g1", mayUse: false)
        let none = DaemonAPI.ProviderSummary(id: ProviderID(rawValue: "dk"), name: "Docker", kind: "commands")
        #expect(GroupWords.providerLine(given, groups: [platform]) == "For Platform")
        #expect(GroupWords.providerLine(none, groups: [platform]) == "For admins only")
        #expect(GroupWords.providerLine(none, groups: []) == nil)
        #expect(GroupWords.providers(platform, of: [given, none]) == "DigitalOcean")
        #expect(GroupWords.mayNotUse(given, groups: [platform]) == "Only Platform can start machines from DigitalOcean.")
        #expect(!given.usable && none.usable)
    }
}

/// A bot's words in Settings ▸ People (#1761), as `teamGroups.ts` says them.
@Suite("Bot words")
struct BotWordsTests {
    @Test func aBotsLineSaysItsGroupCapAndSpend() {
        let platform = DaemonAPI.Group(id: "g1", name: "Platform")
        let bot = DaemonAPI.PersonRow(id: "b", name: "review-bot", kind: .bot, role: .member, group: "g1",
                                      caps: DaemonAPI.SpendCaps(dailyUSD: 50), spentTodayUSD: 3.2)
        #expect(BotWords.line(bot, groups: [platform]) == "In Platform · $50 a day · $3.20 today")
        #expect(BotWords.cap(nil) == "No cap")
        #expect(BotWords.parseCap(" $12.5 ") == 12.5)
        #expect(BotWords.parseCap("none") == nil)
        let reached = DaemonAPI.CapReached(user: "b", name: "review-bot", group: "Platform", spentUSD: 51, capUSD: 50,
                                           until: Date())
        #expect(BotWords.capReached(reached)
            == "review-bot stopped at Platform’s cap: $51 of $50 today. It starts work again at midnight UTC.")
    }
}
