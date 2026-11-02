import AgentsKitCore
import SwiftUI

/// The words of the pause card (#3004, US3); the web page's are in
/// `Web/src/model/desktopControlWords.ts`.
enum DesktopControlPauseWords {
    static let symbol = "hand.raised"
    static func title(_ app: String) -> String {
        app.isEmpty ? "Paused: you used the mouse or keyboard" : "Paused driving \(app): you used the mouse or keyboard"
    }
    static let body = "The agent stopped so it does not fight you for the screen. Resume lets it go on from where it stopped. Take Over gives you the screen back for the rest of this turn."
    static let resume = "Resume"
    static let takeOver = "Take Over"
    static let takeOverHelp = "Let go of the screen lease now. The agent does not drive the screen again in this turn."
}

/// An agent's `drive_screen` paused by the person's own touch (#3004, US3, FR-007), as a card
/// at the end of the transcript, the way an ask to be archived is (`ArchiveRequestCard`):
/// in the attention tint, with Resume and Take Over. The window and the Remote both draw it
/// while `Agent.desktopControlPause` is set; the web page's is `DesktopControlPauseCard.tsx`.
struct DesktopControlPauseCard: View {
    let pause: DesktopControlPause
    /// Drive on from where it stopped.
    let resume: () async -> Void
    /// Let go of the screen at once (FR-008).
    let takeOver: () async -> Void
    var isDisabled = false

    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(DesktopControlPauseWords.title(pause.app), systemImage: DesktopControlPauseWords.symbol)
                .appText(.reading).fontWeight(.semibold)
                .tinted(.attention)
            Text(DesktopControlPauseWords.body)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button(DesktopControlPauseWords.takeOver) { answer(takeOver) }
                    .buttonStyle(.paper)
                    .help(DesktopControlPauseWords.takeOverHelp)
                    .accessibilityHint(DesktopControlPauseWords.takeOverHelp)
                Button(DesktopControlPauseWords.resume) { answer(resume) }
                    .buttonStyle(.paperProminent)
            }
            .disabled(busy || isDisabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.attention.color?.opacity(0.07) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.attention.color ?? .secondary).opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DesktopControlPauseWords.title(pause.app))
    }

    private func answer(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}
