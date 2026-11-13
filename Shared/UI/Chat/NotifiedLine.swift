import AgentsKitCore
import SwiftUI

/// What an agent told the person with `notify` (#2805), where it called it, as a Line (#5036):
/// a bell, the title in bold, then the body, the time and what became of the notification.
/// Not a bubble, since the agent did not say it in its reply; not a card, since it has
/// nothing to answer. The web page's "notified" row draws the same.
struct NotifiedLine: View {
    let id: UUID
    let notice: SentNotice
    let at: Date
    /// Lit a moment when a tap on its notification opened the chat here (#2860).
    @Environment(\.highlightedEntry) private var highlighted
    /// Where to say it is once lit: the pane goes to turns, not to the lines in them.
    @Environment(\.revealLine) private var reveal
    @State private var top: CGFloat?
    @State private var revealed = false

    var body: some View {
        // A Line (#5036): the title, then the body, the time and what became of it.
        RecordLine(icon: LineGlyph.notified, head: notice.title,
                   detail: ([notice.body].compactMap { $0 }
                            + [at.formatted(date: .omitted, time: .shortened), notice.outcomeText()])
                       .joined(separator: " \u{00B7} "))
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(highlighted == id ? 0.18 : 0))
                .padding(-6)
        }
        .accessibilityElement(children: .combine)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TranscriptStack.space)).minY } action: {
            top = $0
            revealIfLit()
        }
        .onChange(of: highlighted == id, initial: true) { _, lit in
            if !lit { revealed = false }
            revealIfLit()
        }
    }

    private func revealIfLit() {
        guard highlighted == id, !revealed, let top else { return }
        revealed = true
        reveal.go(top)
    }
}

/// Takes the pane to a line at a place in the transcript's rows (#2860). In a struct, as
/// `ChatActions` is: a closure alone in the environment is never equal to the last one.
struct LineRevealer {
    var go: @MainActor (CGFloat) -> Void = { _ in }
}

extension EnvironmentValues {
    /// The transcript line just gone to from elsewhere, lit for a moment (#2860).
    @Entry var highlightedEntry: UUID? = nil
    /// Takes the pane to a line at this place in the transcript's rows (#2860).
    @Entry var revealLine = LineRevealer()
}
