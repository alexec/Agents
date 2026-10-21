import AgentsKitCore
import Foundation

/// The words and the symbol for a file an agent showed that the person has not looked at
/// (#1802), once for both apps. The web page says the same in `fileToSeeWords.ts`.
///
/// It is a mark on the row, as unread is: never a group, never on a badge. The daemon puts
/// it on `Agent.fileToSee` and takes it away when the conversation is read.
enum FileToSeeWords {
    static let symbol = "doc.text.magnifyingglass"

    /// "File to see: report.md", or nil for a session with nothing to see.
    static func line(_ agent: Agent?) -> String? {
        agent?.fileToSee.map { "File to see: \($0.name)" }
    }

    /// The row's grey line in the report's place: the file to see while it is unseen, then
    /// the report. Said in words, not only by the mark, because a touch screen has no
    /// hover to name it (#1873).
    static func reportLine(_ agent: Agent) -> String? {
        line(agent) ?? agent.report?.message
    }
}
