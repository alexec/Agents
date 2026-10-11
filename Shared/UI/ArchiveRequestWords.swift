import AgentsKitCore
import Foundation

/// The words and the symbol for an agent's `archive_session` that waits for the person to
/// approve archiving (#584, #649), once for both apps. The web page says the same in
/// `archiveWords.ts`.
///
/// Whether a session carries the mark is `Agent.asksToArchive`'s to decide; this only
/// says what the mark and its buttons are called.
enum ArchiveRequestWords {
    static let symbol = "archivebox"

    /// The mark on the row and over the chat.
    static let mark = "Archiving needs approval"

    /// The one click that approves it, and archives the session.
    static let archive = "Approve"

    /// What the Approve Archiving group's button does: every session in it.
    static let archiveAll = "Approve All"

    /// The tooltip and the accessibility hint for Approve beside the mark.
    static let archiveHelp = "The agent is done with this session: approve archiving it"

    /// For Approve All, with how many.
    static func archiveAllHelp(_ count: Int) -> String {
        count == 1 ? "Approve archiving the session that waits for it"
            : "Approve archiving the \(count) sessions that wait for it"
    }

    /// "Archiving needs approval", or nil for a session that does not.
    static func line(_ agent: Agent?) -> String? {
        agent?.asksToArchive == true ? mark : nil
    }
}
