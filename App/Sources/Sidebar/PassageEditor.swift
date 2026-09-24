import SwiftUI

/// One passage of a live page, open for typing.
///
/// A plain text editor over that passage's Markdown source, in the page's own face and
/// at its own width, so that opening it moves nothing: the words stay where they were
/// and a caret appears among them. Only one passage is ever open, and it holds only
/// its own source — which is what makes an agent's write elsewhere in the file cheap
/// to absorb: the rest of the page re-renders around this editor, and nothing under
/// the caret is replaced (022 FR-012).
///
/// There is no "done". A pause writes; losing focus writes and closes; Escape closes,
/// writing first if there is anything to write. Return is a newline, because a passage
/// may be several lines long and a control that sent instead would eat the paragraph
/// break the person meant.
struct PassageEditor: View {
    @Binding var draft: String
    /// The draft is due on disk: a pause, or the editor closing.
    let onCommit: () -> Void
    /// The person is done here.
    let onClose: () -> Void

    @FocusState private var isFocused: Bool
    @State private var pause: Task<Void, Never>?

    /// How long after the last keystroke the draft goes to disk. Long enough that a
    /// sentence typed at speed is one write, not twenty; short enough to be inside
    /// the spec's two seconds with room for the round trip (SC-003).
    static let pauseBeforeSaving: Duration = .seconds(1)

    var body: some View {
        TextEditor(text: $draft)
            .font(.system(.callout, design: .serif))
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            // `TextEditor` insets its text by a few points that a `Text` does not;
            // pulled back so the first character sits where the rendered one did.
            .padding(.horizontal, -5)
            .padding(.vertical, -1)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onChange(of: draft) {
                pause?.cancel()
                pause = Task {
                    try? await Task.sleep(for: Self.pauseBeforeSaving)
                    guard !Task.isCancelled else { return }
                    onCommit()
                }
            }
            .onChange(of: isFocused) { _, focused in
                guard !focused else { return }
                pause?.cancel()
                onCommit()
                onClose()
            }
            .onKeyPress(.escape) {
                pause?.cancel()
                onCommit()
                onClose()
                return .handled
            }
            .onDisappear { pause?.cancel() }
    }
}
