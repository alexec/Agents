import Foundation

/// The four tones of a message (#4737, docs/reference/design-system.md, "Messages").
///
/// There is no warning tone: a warning is a status (neutral) or a failure. Orange is only
/// for a person who is needed (specs/018 FR-006a), so a cost limit that stopped the work is
/// a failure.
public enum MessageTone: String, Sendable, CaseIterable {
    /// A status: offline, stale, in progress, set by the organisation. No tint.
    case neutral
    /// A person is needed: pair, sign in, approve, choose the folder again.
    case attention
    /// Something failed: a read, an action, a limit that stopped the work.
    case failure
    /// An ending the app can vouch for: done, sent, archived.
    case success

    /// The SF Symbol that goes with the words. A message never shows colour alone.
    public var symbol: String {
        switch self {
        case .neutral: "info.circle"
        case .attention: "exclamationmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    /// The symbol of a neutral banner about a machine that cannot be reached.
    public static let offlineSymbol = "wifi.slash"
}

/// How long a toast stays (#4737): a success 4 seconds, a toast with Undo 8 seconds, and a
/// failure until the person closes it. The time stops while the pointer, the focus or
/// VoiceOver is on the toast; the view does that.
public enum ToastTime {
    public static let success: Double = 4
    public static let undo: Double = 8

    /// The seconds before the toast goes by itself, or nil when it stays until it is closed.
    public static func seconds(tone: MessageTone, undo hasUndo: Bool) -> Double? {
        if tone == .failure { return nil }
        return hasUndo ? undo : success
    }
}
