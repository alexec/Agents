import AgentsKitCore
import Foundation

/// A working session's mark while it runs a tool (#1902), once for both apps. The web page
/// draws the same in `SessionRow.tsx`. Thinking and replying keep the Working spinner.
enum RunningToolWords {
    /// One symbol for every tool: six kinds in a small well are hard to tell apart, and
    /// the words name the tool.
    static let symbol = "wrench.and.screwdriver"

    /// The tool a working session runs, or nil while it thinks.
    static func tool(_ agent: Agent) -> String? {
        agent.state == .running ? agent.runningTool : nil
    }

    /// "Running: swift test", for the tooltip and VoiceOver.
    static func label(_ tool: String) -> String { "Running: \(tool)" }
}
