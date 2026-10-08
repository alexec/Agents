import Foundation

/// What a workflow's run may do with its own session once it is done (#433).
///
/// `when-done:` in the file, set by the person who wrote the workflow and never by the
/// agent, as a starting agent decides for its helpers. Only a session the workflow
/// started gets it: a triggering workflow borrows somebody else's, which stays theirs.
public enum WorkflowWhenDone: String, Codable, Hashable, Sendable, CaseIterable {
    /// The run may park itself, and nothing more. The default, and a file that does
    /// not say: the person looks at every run.
    case park
    /// The run may finish with `afterwards: archive` when there is nothing to look at.
    case archiveAllowed = "archive-allowed"
    /// The daemon archives the run's session when it finishes done or nothing_to_do,
    /// whatever the agent asks for.
    case archive

    /// The key, as the file spells it.
    public static let key = "when-done"

    /// Said when the file names a value that is none of the three.
    public static let unknown = "`when-done:` must be park, archive-allowed or archive"

    /// The menu's words for it, the same on every page.
    public var words: String {
        switch self {
        case .park: "Keep each run"
        case .archiveAllowed: "Let a run archive itself"
        case .archive: "Archive each finished run"
        }
    }

    /// What it means, in a sentence under the menu.
    public var sentence: String {
        switch self {
        case .park:
            "Every run stays in the list when it is done. A run may park itself."
        case .archiveAllowed:
            "A run that finishes done or with nothing to do may archive itself when there is nothing to look at. Otherwise it stays."
        case .archive:
            "A run that finishes done or with nothing to do is archived. One that needs you, is stuck or is blocked stays."
        }
    }

    /// The text the file says it with, or nil to leave the line out: `park` is what a
    /// file that does not say means, so choosing it again leaves the file as it was.
    public var fileText: String? { self == .park ? nil : rawValue }

    /// Whether a run's ask to archive itself is allowed.
    public var allowsArchiveAsk: Bool { self != .park }
}
