import Foundation

/// What the host says on a folder's pull request when it merges (#2352): nothing, the
/// tokens and time only, or the cost too. The folder's `.agents/folder.json` keeps it, so
/// the people of a public repo choose what it publishes. Off is the default.
public enum PRCostComment: String, Codable, Sendable, CaseIterable {
    case off, tokens, cost

    /// The picker's words, as the web page's `prCostCommentWords` says them.
    public var words: String {
        switch self {
        case .off: "Off"
        case .tokens: "Tokens and time"
        case .cost: "Cost, tokens and time"
        }
    }

    /// What Folder Settings says under the picker.
    public static let help = "When a pull request of this folder's repository merges, "
        + "Agents comments on it with what its work cost, and edits that comment when more comes in. "
        + "A public repository's comment is public."
}
