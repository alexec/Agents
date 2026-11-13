import AgentsKitCore
import SwiftUI

/// A use of a secret with Ask before use (#4017, #4918), as a card at the end of the chat of
/// the session that asked, as a permission question is: which secret, and where its value
/// goes, never the value; its buttons are the request's answers, the same ones as its Needs
/// You row's menu, and they go the same way (`answerSecretUse`). The card goes when the
/// request is answered on any client. A terminal's (#4179) has no session, so it has no card.
/// The window and the Remote both draw it; the web page's is `SecretUseCard.tsx`.
struct SecretUseCard: View {
    let request: NeedRequest
    let use: NeedRequest.SecretUse
    /// Send this answer; whether it went.
    let answer: (NeedRequest.Action) async -> Void
    var isDisabled = false

    @State private var busy = false

    private var title: String { request.title(asker: nil) }

    var body: some View {
        // An Ask (#5031): Deny on the left, Approve last and prominent, the one beside it, and the
        // rest in ⋯ (spec rule 2).
        AskCard(icon: request.symbol, title: title) {
            Text(use.where)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } decline: {
            if use.actions.contains(.deny) {
                AskDecline(NeedRequest.Action.deny.word) { send(.deny) }
                    .disabled(busy || isDisabled)
            }
        } buttons: {
            Group {
                if !more.isEmpty {
                    Menu {
                        ForEach(more, id: \.self) { action in
                            Button(action.word) { send(action) }
                        }
                    } label: {
                        Image(icon: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.paper)
                    .fixedSize()
                    .accessibilityLabel("More answers")
                }
                if let second = approving.dropFirst().first {
                    Button(second.word) { send(second) }
                        .buttonStyle(.paper)
                }
                if let primary = approving.first {
                    Button(primary.word) { send(primary) }
                        .buttonStyle(.paperProminent)
                }
            }
            .disabled(busy || isDisabled)
        }
    }

    /// The answers that allow, the primary first.
    private var approving: [NeedRequest.Action] { use.actions.filter { $0 != .deny } }
    /// Past the foot's two buttons.
    private var more: [NeedRequest.Action] { Array(approving.dropFirst(2)) }

    private func send(_ action: NeedRequest.Action) {
        busy = true
        Task {
            await answer(action)
            busy = false
        }
    }
}
