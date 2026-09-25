import AgentsKitCore
import SwiftUI

/// What the shared chat views need from whichever app is drawing them (033).
///
/// The transcript rows are one copy in both apps, and they touch the app in three places
/// only: opening a file a tool call touched, reading a command's output, and taking a
/// queued prompt back. Each app says what those mean for it here, once, at the top of
/// the chat. On the Mac a file opens in the Mac's editor; on a phone it opens in the
/// phone's Files pane, read from the Mac, at the line the call named (034). That is the
/// whole of the difference, and it is why this is three closures rather than a model.
///
/// The defaults do nothing, so a preview draws without an app behind it.
struct ChatActions {
    var open: @MainActor (ToolCallLocation) -> Void = { _ in }
    var terminalOutput: @MainActor (String) -> String = { _ in "" }
    var unqueue: @MainActor (QueuedPrompt, UUID) async -> Void = { _, _ in }
}

extension EnvironmentValues {
    @Entry var chatActions = ChatActions()
}
