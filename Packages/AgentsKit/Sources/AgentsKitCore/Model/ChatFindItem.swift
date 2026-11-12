/// How the Find in Chat item is drawn (#1867): enabled in a chat its host can find in, greyed
/// with "This host needs an update to do this." on a host too old to find (#1748), and greyed
/// with no chat open. On the Mac it always has ⌘F (#4787): the key is Find in Chat's, and never
/// moves the keyboard to Find Session, which ⌥⌘F and ⌘K reach.
/// The page has its own copy (`findInChatItem` in `Web/src/views/SessionMenu.tsx`).
public enum ChatFindItem: Equatable, Sendable {
    /// No chat open here (a folder window, nothing chosen): greyed.
    case noChat
    case enabled
    /// A chat on a host too old to find: greyed, with the update help.
    case needsUpdate

    public static func of(chatOpen: Bool, hostFinds: Bool) -> ChatFindItem {
        guard chatOpen else { return .noChat }
        return hostFinds ? .enabled : .needsUpdate
    }

    public var isEnabled: Bool { self == .enabled }
}
