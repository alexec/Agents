import AgentsKitCore
import Testing

/// The ⌘K command menu's finding and order (#4787).
struct CommandFinderTests {
    private typealias Item = CommandFinder.Item

    private let items: [Item] = [
        Item(id: "action:archive", kind: .action, title: "Archive Session", shortcut: "⌥⌘⌫"),
        Item(id: "action:new", kind: .action, title: "New Session", shortcut: "⌘N"),
        Item(id: "session:1", kind: .session, title: "Fix the sign-in sheet", detail: "Agents"),
        Item(id: "session:2", kind: .session, title: "Archive old logs", detail: "Tools"),
        Item(id: "folder:/a", kind: .folder, title: "Agents", detail: "This Mac"),
        Item(id: "issue:github:alexec/Agents#4777", kind: .issue, title: "As fast as Linear",
             detail: "alexec/Agents", ref: "#4777"),
        Item(id: "pr:github:alexec/Agents#4809", kind: .pr, title: "Inline error text",
             detail: "alexec/Agents", ref: "#4809"),
    ]

    @Test func noWordsKeepsTheOrderGiven() {
        #expect(CommandFinder.matches(items, query: "  ").map(\.id) == items.map(\.id))
        #expect(CommandFinder.matches(items, query: "", limit: 2).count == 2)
    }

    @Test func everyWordMustBeInTheItem() {
        #expect(CommandFinder.matches(items, query: "sign sheet").map(\.id) == ["session:1"])
        #expect(CommandFinder.matches(items, query: "sign nothing").isEmpty)
    }

    @Test func aTitleThatStartsWithTheQueryComesFirst() {
        // Both say "archive"; the action's title starts with it, the session's too, so the
        // kinds' order (actions first) settles it.
        #expect(CommandFinder.matches(items, query: "archive").map(\.id) == ["action:archive", "session:2"])
        // "in" starts "Inline" and the "in" of "sign-in": the title that starts with it first.
        #expect(CommandFinder.matches(items, query: "in").first?.id == "pr:github:alexec/Agents#4809")
    }

    @Test func aRefFindsItsItemAboveWords() {
        #expect(CommandFinder.matches(items, query: "#4777").first?.id == "issue:github:alexec/Agents#4777")
        #expect(CommandFinder.matches(items, query: "4777").first?.id == "issue:github:alexec/Agents#4777")
        #expect(CommandFinder.matches(items, query: "P#4809").first?.id == "pr:github:alexec/Agents#4809")
    }

    @Test func theDetailFindsToo() {
        #expect(CommandFinder.matches(items, query: "tools").map(\.id) == ["session:2"])
    }

    @Test func aTypedRef() {
        #expect(CommandFinder.typedRef("#12")?.number == 12)
        #expect(CommandFinder.typedRef("12")?.pr == nil)
        #expect(CommandFinder.typedRef("P#12")?.pr == true)
        #expect(CommandFinder.typedRef("!7")?.pr == true)
        #expect(CommandFinder.typedRef("#") == nil)
        #expect(CommandFinder.typedRef("fix 12") == nil)
        #expect(CommandFinder.typedRef("#0") == nil)
    }

    @Test func aRefNoItemHasOpensInEachRepo() {
        let made = CommandFinder.refItems("#5", repos: ["github:alexec/Agents"], known: items)
        #expect(made.map(\.id) == ["issue:github:alexec/Agents#5", "pr:github:alexec/Agents#5"])
        #expect(made.first?.title == "Open issue #5")
        #expect(made.first?.detail == "alexec/Agents")
        // A PR's ref says it is one; GitLab's merge requests take `!`.
        #expect(CommandFinder.refItems("P#5", repos: ["gitlab:o/r"], known: []).map(\.id) == ["pr:gitlab:o/r!5"])
        // One the menu has already is not made again.
        #expect(CommandFinder.refItems("#4777", repos: ["github:alexec/Agents"], known: items).map(\.id)
            == ["pr:github:alexec/Agents#4777"])
        #expect(CommandFinder.refItems("fix", repos: ["github:alexec/Agents"], known: []).isEmpty)
    }
}
