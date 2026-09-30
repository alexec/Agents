import Foundation

/// Where a tap on the widget means to go (068).
///
/// One form for both ends: the widget builds a URL with `url`, and the app reads it with
/// `parse`. It is here, in Core, rather than in either app because it is the one piece of
/// this feature that can be tested without a widget, a simulator or a device — and because
/// the two sides must agree on it exactly, which is the sort of thing that goes wrong
/// quietly and is only noticed on a phone.
public enum AttentionLink: Hashable, Sendable {

    /// The widget as a whole, or the small one, which has no rows: whatever needs you now,
    /// newest first. The app decides which conversation that is (FR-010).
    case attention

    /// One session, named by its agent.
    case agent(UUID)

    /// The scheme, registered by the Remote's `Info.plist`.
    public static let scheme = "agents"

    public var url: URL {
        switch self {
        case .attention:
            return URL(string: "\(Self.scheme)://attention") ?? URL(string: "about:blank")!
        case .agent(let id):
            return URL(string: "\(Self.scheme)://agent/\(id.uuidString)") ?? URL(string: "about:blank")!
        }
    }

    /// What a URL means, or nil for anything that is not ours — a link from a notification
    /// centre that never arrived, a scheme from another app, a half-written agent id. A
    /// URL that cannot be read is ignored rather than guessed at (FR-016).
    public static func parse(_ url: URL) -> AttentionLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "attention":
            return .attention
        case "agent":
            guard url.pathComponents.count == 2, let id = UUID(uuidString: url.pathComponents[1]) else { return nil }
            return .agent(id)
        default:
            return nil
        }
    }
}
