import SwiftUI

/// The way back to the live end of a conversation.
///
/// Shown only when it would do something: there is more transcript than pane, and the
/// reader is not following the end. No colour — the house rule is that colour means
/// something has gone wrong, and being three screens up a conversation is not something
/// going wrong. One arrow and nothing else (#1515): it does not say what arrived or
/// where a question waits, so it has no state to get wrong.
struct JumpToEnd: View {
    let go: () -> Void

    #if os(iOS)
    private static let touch: CGFloat = 1.4
    #else
    private static let touch: CGFloat = 1
    #endif

    var body: some View {
        Button(action: go) {
            Image(systemName: "arrow.down")
                // Decorative: a glyph in a capsule, not text (FR-015).
                .glyph(size: 10, weight: .semibold)
                // A thumb, not a pointer, on a touch screen: the same capsule, larger.
                .padding(.horizontal, 9 * Self.touch)
                .padding(.vertical, 7 * Self.touch)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .appText(.fine)
        .fixedSize()
        .paperRaised(in: .capsule)
        .help("Go to the end")
        .accessibilityLabel("Go to the end of the conversation")
    }
}
