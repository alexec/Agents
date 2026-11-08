import AgentsKitCore
import SwiftUI

/// Ask before use (#4016): the toggle, and under it what on and off mean. On the `ask_secret`
/// card (the window and the Remote), Add for a Session… and Your setup's Add and Replace.
/// The web page draws the same with `askBeforeUseWords`.
struct AskBeforeUseToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(AskBeforeUseWords.toggle, isOn: $isOn)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .appText(.supporting)
            Text(AskBeforeUseWords.hint(isOn))
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
