import Foundation

/// Every word about Mute Notifications (#2003), in one place: the window and the Remote
/// both hold this half. The page's copy is in `Web/src/model/mute.ts`.
///
/// A muted session still goes under Needs you and still counts in the badge; its host
/// sends no push, no Mac notification and no banner for it. A muted workflow's runs are
/// muted sessions.
public enum MuteWords {
    public static let mute = "Mute Notifications"
    public static let unmute = "Unmute Notifications"
    /// The row's mark: a bell with a slash.
    public static let symbol = "bell.slash"
    public static let unmuteSymbol = "bell"
    /// The mark's spoken value and tooltip.
    public static let muted = "Notifications muted"

    public static func label(muted: Bool) -> String { muted ? unmute : mute }
    public static func symbol(muted: Bool) -> String { muted ? unmuteSymbol : symbol }

    public static func help(muted: Bool) -> String {
        muted ? "Send notifications for this session again"
              : "Send no notifications for this session. It still shows under Needs You"
    }

    public static func workflowHelp(muted: Bool) -> String {
        muted ? "Send notifications for this workflow's runs again. Takes muted: true out of its file"
              : "Send no notifications for this workflow's runs. They still show under Needs You. Writes muted: true into its file"
    }
}
