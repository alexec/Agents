import AgentsKitCore
import SwiftUI

/// How much of a runtime's plan window is used, as a bar under the reading's words
/// on the Runtimes page (#1097). Drawn only when the reading has an amount: a reset
/// time alone fills nothing. Red when spent, orange when nearly spent, the accent
/// otherwise. It says nothing the words above it do not, so it is hidden from
/// VoiceOver, which reads the words.
struct AllowanceBar: View {
    let reading: AllowanceReading

    var body: some View {
        if let used = reading.usedFraction {
            ProgressView(value: used)
                .progressViewStyle(.linear)
                .tint(tint(used))
                .frame(maxWidth: 240)
                .accessibilityHidden(true)
        }
    }

    private func tint(_ used: Double) -> Color {
        if reading.spent || used >= 1 { return StateTint.failure.color ?? Paper.accent }
        if reading.nearlySpent || used >= 0.8 { return StateTint.attention.color ?? Paper.accent }
        return Paper.accent
    }
}
