import Foundation

/// The parts of running a command from a reply that are the same on the Mac and phone.
/// Each client still owns its `ShellClient` and how it sends the resulting prompt.
public enum ShellCommandActions {
    public static let unavailableMessage = "The session's shell did not start, so the command did not run."

    /// Wait briefly for the pane to attach, reopen a closed shell, and type the command.
    /// Returns false when the shell could not be made ready.
    @MainActor
    @discardableResult
    public static func run(_ command: String, in shell: ShellClient) async -> Bool {
        for _ in 0..<30 where !shell.isAttached {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Shell 0 can close while the agent stays open (#1681).
        if !shell.isAttached { await shell.attach(rows: 0, cols: 0) }
        if shell.isAttached, !shell.state.isLive { await shell.startAgain() }
        guard shell.isAttached, shell.state.isLive else { return false }
        shell.beginRecent()
        shell.type(ShellCommand.typed(command))
        return true
    }

    /// Build the prompt for Tell the Agent from the command and the shell's recent output.
    public static func report(_ command: String, recent: Data) -> String {
        ShellCommand.report(command: command, printed: ShellCommand.tail(recent))
    }
}
