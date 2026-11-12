import AgentsKitCore
import Testing

/// Find in Chat on a host too old to find (#1867): kept in the menu, greyed.
struct ChatFindItemTests {
    @Test func anOldHostsChatKeepsTheItemGreyed() {
        let item = ChatFindItem.of(chatOpen: true, hostFinds: false)
        #expect(item == .needsUpdate)
        #expect(!item.isEnabled)
    }

    @Test func aHostThatFindsHasTheItem() {
        #expect(ChatFindItem.of(chatOpen: true, hostFinds: true).isEnabled)
    }

    /// ⌘F is always Find in Chat (#4787): with no chat, greyed, not Find Session.
    @Test func noChatGreysTheItem() {
        #expect(ChatFindItem.of(chatOpen: false, hostFinds: true) == .noChat)
        #expect(!ChatFindItem.of(chatOpen: false, hostFinds: false).isEnabled)
    }
}
