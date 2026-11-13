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
/// at the end of the transcript, as an Ask (`AskCard`, #5031), with Resume and Take Over. The window and the Remote both draw it
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
        // An Ask (#5031): Take Over beside Resume, the primary.
        AskCard(icon: DesktopControlPauseWords.symbol, title: DesktopControlPauseWords.title(pause.app)) {
            Text(DesktopControlPauseWords.body)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Group {
                Button(DesktopControlPauseWords.takeOver) { answer(takeOver) }
                    .buttonStyle(.paper)
                    .help(DesktopControlPauseWords.takeOverHelp)
                    .accessibilityHint(DesktopControlPauseWords.takeOverHelp)
                Button(DesktopControlPauseWords.resume) { answer(resume) }
                    .buttonStyle(.paperProminent)
            }
            .disabled(busy || isDisabled)
        }
    }

    private func answer(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}
