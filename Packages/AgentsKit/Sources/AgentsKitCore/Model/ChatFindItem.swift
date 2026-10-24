/// How the Find in Chat item is drawn (#1867): in the menu wherever a chat is open, greyed
/// with "This host needs an update to do this." on a host too old to find (#1748). On the Mac
/// it keeps ⌘F while it is in the menu, so the key never goes to Find Session in a chat.
/// The page has its own copy (`findInChatItem` in `Web/src/views/SessionMenu.tsx`).
public enum ChatFindItem: Equatable, Sendable {
    /// No chat open here (a folder window, nothing chosen): ⌘F is Find Session's.
    case hidden
    case enabled
    /// A chat on a host too old to find: in the menu, greyed, with the update help.
    case needsUpdate

    public static func of(chatOpen: Bool, hostFinds: Bool) -> ChatFindItem {
        guard chatOpen else { return .hidden }
        return hostFinds ? .enabled : .needsUpdate
    }

    /// The item is in the menu, and on the Mac takes ⌘F.
    public var isShown: Bool { self != .hidden }
    public var isEnabled: Bool { self == .enabled }
}
