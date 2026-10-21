import AgentsKitCore
import Testing

/// Find in Chat on a host too old to find (#1867): kept in the menu, greyed.
struct ChatFindItemTests {
    @Test func anOldHostsChatKeepsTheItemGreyed() {
        let item = ChatFindItem.of(chatOpen: true, hostFinds: false)
        #expect(item == .needsUpdate)
        #expect(item.isShown)
        #expect(!item.isEnabled)
    }

    @Test func aHostThatFindsHasTheItem() {
        let item = ChatFindItem.of(chatOpen: true, hostFinds: true)
        #expect(item.isShown && item.isEnabled)
    }

    @Test func noChatNoItem() {
        #expect(ChatFindItem.of(chatOpen: false, hostFinds: true) == .hidden)
        #expect(!ChatFindItem.of(chatOpen: false, hostFinds: false).isShown)
    }
}
