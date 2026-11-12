import AgentsKitCore
import SwiftUI

/// A prompt sent from here that its host has not yet written in the transcript (#4814):
/// the person's bubble, drawn as the prompt bar empties, so a send shows at once. Dimmed
/// until the host's own entry takes its place; a send that fails takes it away and gives
/// the words back to the prompt bar.
struct SendingPromptRow: View {
    let prompt: AgentsModel.SendingPrompt

    var body: some View {
        Text(prompt.text)
            .appText(.reading)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(12)
            .paperWell(in: RoundedRectangle(cornerRadius: 12))
            .padding(.leading, 60)
            .frame(maxWidth: .infinity, alignment: .trailing)
            // One element, so the label never sits over a child's (stacked labels crash AppKit).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sending: \(prompt.text)")
    }
}
