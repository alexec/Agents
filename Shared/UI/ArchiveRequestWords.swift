import AgentsKitCore
import Foundation

/// The words and the symbol for an agent's request to archive a session, once for both
/// apps (#584, which replaced parking). The web page says the same in `archiveWords.ts`.
///
/// Whether a session carries the mark is `Agent.asksToArchive`'s to decide; this only
/// says what the mark and its buttons are called.
enum ArchiveRequestWords {
    static let symbol = "archivebox"

    /// The mark on the row and over the chat.
    static let mark = "Asks to archive"

    /// The one click that agrees.
    static let archive = "Archive"

    /// What the To Archive group's button does: every session in it.
    static let archiveAll = "Archive All"

    /// The tooltip and the accessibility hint for Archive beside the mark.
    static let archiveHelp = "The agent is done with this session: archive it"

    /// For Archive All, with how many.
    static func archiveAllHelp(_ count: Int) -> String {
        count == 1 ? "Archive the session that asks to be archived"
            : "Archive the \(count) sessions that ask to be archived"
    }

    /// "Asks to archive", or nil for a session that does not.
    static func line(_ agent: Agent?) -> String? {
        agent?.asksToArchive == true ? mark : nil
    }
}
