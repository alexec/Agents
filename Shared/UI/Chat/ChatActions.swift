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
    /// Send a queued prompt into the running turn, and whether this runtime can take one
    /// there at all: what it advertised, by runtime id.
    var sendNow: @MainActor (QueuedPrompt, UUID) async -> Void = { _, _ in }
    var canSendNow: @MainActor (String?) -> Bool = { _ in false }
    /// Show an edit among the rest of what the agent changed (035): the Mac's Changes
    /// pane, at that file and that tool call. Nil where there is no such pane, and then
    /// the edit offers nothing.
    var showEdit: (@MainActor (ToolCallContent.Diff, String?) -> Void)? = nil
    /// Open a subagent's own steps, by its id (057): the Mac's Background pane, the
    /// phone's sheet. Nil offers nothing.
    var subagentSteps: (@MainActor (String) -> Void)? = nil
    /// Open what a background task printed, from its output file (057).
    var backgroundOutput: (@MainActor (BackgroundItem) -> Void)? = nil
}

extension EnvironmentValues {
    @Entry var chatActions = ChatActions()
    /// The open agent's background work (057), for a tool call to say it runs on.
    @Entry var backgroundWork: [BackgroundItem] = []
}
