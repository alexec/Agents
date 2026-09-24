import SwiftUI

/// The way back to the live end of a conversation.
///
/// Shown only when it would do something: there is more transcript than pane, and the
/// reader is not already at the foot of it. No colour — the house rule is that colour
/// means something has gone wrong, and being three screens up a conversation is not
/// something going wrong. New lines arriving while you read are said in words.
struct JumpToEnd: View {
    /// Whether anything has arrived since the reader scrolled away.
    let hasNewBelow: Bool
    let go: () -> Void

    var body: some View {
        Button(action: go) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    // Decorative: a glyph in a capsule, not text (FR-015).
                    .font(.system(size: 10, weight: .semibold))
                if hasNewBelow {
                    Text("Something new")
                }
            }
            .padding(.horizontal, hasNewBelow ? 12 : 9)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .appText(.fine)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(hasNewBelow ? "Go to the end, where something new is" : "Go to the end")
        .accessibilityLabel(hasNewBelow
                            ? "Go to the end of the conversation, where something new is"
                            : "Go to the end of the conversation")
    }
}
