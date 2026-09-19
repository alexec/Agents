import AgentsKit
import SwiftUI

/// What the agent thinks you might want to ask next, offered rather than sent.
///
/// Tapping one puts it in the prompt with the cursor after it. It does not go: the
/// agent suggested the words, and sending them is still the user's move. The row sits
/// directly above the field, close enough to read as part of what is about to be sent.
struct SuggestedPromptRow: View {
    let prompts: [SuggestedPrompt]
    let choose: (SuggestedPrompt) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(prompts) { prompt in
                Button {
                    choose(prompt)
                } label: {
                    Text(prompt.label)
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .font(.footnote)
                .help(prompt.prompt)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
