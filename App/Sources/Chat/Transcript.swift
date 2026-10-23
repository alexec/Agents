import AgentsKitCore
import SwiftUI

/// What the agent has said and done, as the Mac's window hands it to the shared chat.
///
/// The rows and the way the pane moves through them are `ChatTranscript`'s, which the
/// phone draws too (033). What is left here is where each input comes from on a Mac.
struct Transcript: View {
    @Environment(AppModel.self) private var model
    /// Set in a window of its own (#826), whose page of the transcript is its own.
    @Environment(\.poppedChat) private var popped
    let agent: Agent
    /// How much of the foot of the pane the floating prompt covers.
    var bottomInset: CGFloat = 0
    /// What waits on the person, each drawn where it was asked (#723, #973).
    var cards: [WaitingCard] = []

    var body: some View {
        let page = popped?.work ?? model.work
        ChatTranscript(agent: agent,
                       items: page.transcriptItems,
                       stored: page.turns,
                       hasMore: page.hasMoreOfTheConversation,
                       // Turns count as growth at the front too, so an earlier page of
                       // them holds the reader's place as entries do.
                       entryCount: page.entries.count + page.turns.count,
                       isComingBack: model.isComingBack(agent),
                       lastEntryAt: page.lastEntryAt,
                       loadFailure: page.transcriptLoadFailure,
                       settleKey: popped?.id ?? model.selection,
                       loadEarlier: { [popped] in
                           if let popped { await model.loadEarlier(of: popped) } else { await model.loadEarlier() }
                       },
                       bottomInset: bottomInset,
                       cards: cards,
                       // The artifacts pane asked for the message something came
                       // from (FR-042).
                       scrollToEndToken: popped?.scrollToEndToken ?? model.scrollToEndToken,
                       focusedEntry: popped == nil ? model.focusedEntry : nil,
                       focusedIndex: popped == nil ? model.focusedIndex : nil,
                       clearFocus: { if popped == nil { model.clearFocus() } },
                       onFollowing: { page.isFollowingEnd = $0 })
            // Voice mode speaks a turn's reply when it ends (#2322).
            .voiceModeObserves(agent, items: page.transcriptItems, question: model.work.elicitation(for: agent.id),
                               permission: model.work.permission(for: agent.id),
                               approve: { await model.answer($0, optionID: $1) }) {
                await model.answerElicitation($0, action: .accept, content: $1)
            }
    }
}
