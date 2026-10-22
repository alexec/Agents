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

    /// A group's bots are said apart from its people (#2132): a bot names its group itself.
    @Test func botsAreThoseThatNameTheGroup() {
        let platform = DaemonAPI.Group(id: "g1", name: "Platform", members: ["sam"])
        let review = DaemonAPI.PersonRow(id: "b1", name: "review-bot", kind: .bot, role: .member, group: "g1")
        let nightly = DaemonAPI.PersonRow(id: "b2", name: "nightly-bot", kind: .bot, role: .member, group: "g2")
        #expect(GroupWords.bots(platform, people: [sam, review, nightly]) == "review-bot")
        #expect(GroupWords.bots(platform, people: [sam]) == "None")
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
        let reached = DaemonAPI.CapReached(user: "b", name: "review-bot", group: "Platform", spentUSD: 51, capUSD: 50,
                                           until: Date())
        #expect(BotWords.capReached(reached)
            == "review-bot stopped at Platform’s cap: $51 of $50 today. It starts work again at midnight UTC.")
    }

    /// A cap typed in is dollars, no cap when empty, or refused: never no cap for text typed (#2066).
    @Test func aCapTypedInIsDollarsOrRefused() {
        #expect(BotWords.readCap(" $12.5 ") == .dollars(12.5))
        #expect(BotWords.readCap("1,000") == .dollars(1000))
        #expect(BotWords.readCap("$1,000.50") == .dollars(1000.5))
        #expect(BotWords.readCap("50 USD") == .dollars(50))
        #expect(BotWords.readCap("$50 a day") == .dollars(50))
        #expect(BotWords.readCap("50 dollars") == .dollars(50))
        #expect(BotWords.readCap("") == .none)
        #expect(BotWords.readCap(" None ") == .none)
        #expect(BotWords.readCap("€50") == .refused(BotWords.capNotDollars))
        #expect(BotWords.readCap("1,00") == .refused(BotWords.capNotDollars))
        #expect(BotWords.readCap("fifty") == .refused(BotWords.capNotDollars))
        #expect(BotWords.readCap("-5") == .refused(BotWords.capNotDollars))
        #expect(BotWords.readCap("0") == .refused(BotWords.capNotAboveZero))
    }

    /// A cap notice holds only while true: before its until, while its cap and its bot's group stand (#2073).
    @Test func aCapNoticeHoldsOnlyWhileTrue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let until = now.addingTimeInterval(3_600)
        let own = DaemonAPI.CapReached(user: "b", name: "review-bot", spentUSD: 51, capUSD: 50, until: until)
        let grouped = DaemonAPI.CapReached(user: "c", name: "lint-bot", group: "Platform", spentUSD: 90, capUSD: 80, until: until)
        let bot = DaemonAPI.PersonRow(id: "b", name: "review-bot", kind: .bot, role: .member, group: "g1", caps: .init(dailyUSD: 50))
        let other = DaemonAPI.PersonRow(id: "c", name: "lint-bot", kind: .bot, role: .member, group: "g1")
        let group = DaemonAPI.Group(id: "g1", name: "Platform", everyone: false, members: [], caps: .init(dailyUSD: 80))
        #expect(CapNotices.open([own, grouped], people: [bot, other], groups: [group], at: now).count == 2)
        // Its day ended.
        #expect(CapNotices.open([own], people: [bot], groups: [group], at: until).isEmpty)
        // Its cap changed, or its group's.
        var raised = bot
        raised.caps = .init(dailyUSD: 100)
        #expect(CapNotices.open([own], people: [raised], groups: [group], at: now).isEmpty)
        var bigger = group
        bigger.caps = .init(dailyUSD: 200)
        #expect(CapNotices.open([grouped], people: [other], groups: [bigger], at: now).isEmpty)
        // Its bot was removed, or moved to another group.
        #expect(CapNotices.open([own], people: [], groups: [group], at: now).isEmpty)
        var moved = other
        moved.group = "g2"
        #expect(CapNotices.open([grouped], people: [moved], groups: [group], at: now).isEmpty)
        // No list yet: only the time.
        #expect(CapNotices.open([own], people: nil, groups: [], at: now) == [own])
        // One per bot, the last told.
        var again = own
        again.spentUSD = 60
        #expect(CapNotices.adding(again, to: [own, grouped]) == [grouped, again])
    }

    /// A group's cap line adds its bots' spend today (#2074), as the web page's does.
    @Test func aGroupsCapLineAddsItsBotsSpend() {
        let group = DaemonAPI.Group(id: "g1", name: "Platform", caps: .init(dailyUSD: 50))
        let people = [
            DaemonAPI.PersonRow(id: "a", name: "a", kind: .bot, role: .member, group: "g1", spentTodayUSD: 3.2),
            DaemonAPI.PersonRow(id: "b", name: "b", kind: .bot, role: .member, group: "g1", spentTodayUSD: 8.8),
            DaemonAPI.PersonRow(id: "c", name: "c", kind: .bot, role: .member, group: "g2", spentTodayUSD: 40),
        ]
        #expect(GroupWords.capLine(group, people: people) == "$50 a day · $12 today")
        #expect(GroupWords.capLine(DaemonAPI.Group(id: "g2", name: "Ops"), people: []) == "No cap")
    }
}
