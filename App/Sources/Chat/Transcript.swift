import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// What the agent has said and done, as the Mac's window hands it to the shared chat.
///
/// The rows and the way the pane moves through them are `ChatTranscript`'s, which the
/// phone draws too (033). What is left here is where each input comes from on a Mac.
struct Transcript: View {
    @Environment(AppModel.self) private var model
    /// Off unless View ▸ Show Thinking is on. The record still has the thinking.
    @AppStorage(ThinkingDisplay.defaultsKey) private var showsThinking = false
    let agent: Agent
    /// How much of the foot of the pane the floating prompt covers.
    var bottomInset: CGFloat = 0

    private var items: [TranscriptItem] {
        showsThinking ? model.transcriptItems : model.transcriptItems.omittingThoughts()
    }

    var body: some View {
        ChatTranscript(agent: agent,
                       items: items,
                       stored: model.work.turns,
                       hasMore: model.transcriptHasMore,
                       // Turns count as growth at the front too, so an earlier page of
                       // them holds the reader's place as entries do.
                       entryCount: model.entries.count + model.work.turns.count,
                       isComingBack: model.isComingBack(agent),
                       settleKey: model.selection,
                       loadEarlier: { await model.loadEarlier() },
                       bottomInset: bottomInset,
                       // The artifacts pane asked for the message something came
                       // from (FR-042).
                       scrollToEndToken: model.scrollToEndToken,
                       focusedEntry: model.focusedEntry,
                       clearFocus: { model.clearFocus() },
                       onFollowing: { model.work.isFollowingEnd = $0 })
    }
}
