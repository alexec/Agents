import AgentsKitCore
import Foundation

/// A working session's words while it runs a tool (#1902), once for both apps. The mark is
/// one turning cog for every tool (`TurningCog`, #2044): six kinds in a small well are hard
/// to tell apart, and the words name the tool. The web page draws the same in
/// `SessionRow.tsx`. Thinking and replying have the dots (`ThinkingDots`).
enum RunningToolWords {
    /// The tool a working session runs, or nil while it thinks.
    static func tool(_ agent: Agent) -> String? {
        agent.state == .running ? agent.runningTool : nil
    }

    /// "Running: swift test", for the tooltip and VoiceOver.
    static func label(_ tool: String) -> String { StatusShape.runningLabel(tool) }
}
