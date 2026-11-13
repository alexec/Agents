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
        VStack(alignment: .leading, spacing: 10) {
            Label(title, icon: request.symbol)
                .appText(.reading).fontWeight(.semibold)
                .tinted(.attention)
            Text(use.where)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A narrow column (the phone, a large text size) stacks them, so no word is cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    buttons
                }
                VStack(alignment: .trailing, spacing: 8) {
                    buttons
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .disabled(busy || isDisabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.lineAttention))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// Deny first, Approve last and prominent, as the archive card's Keep and Archive are.
    @ViewBuilder private var buttons: some View {
        ForEach(use.actions.reversed(), id: \.self) { action in
            if action == .once {
                Button(action.word) { send(action) }
                    .buttonStyle(.paperProminent)
            } else {
                Button(action.word) { send(action) }
                    .buttonStyle(.paper)
            }
        }
    }

    private func send(_ action: NeedRequest.Action) {
        busy = true
        Task {
            await answer(action)
            busy = false
        }
    }
}
