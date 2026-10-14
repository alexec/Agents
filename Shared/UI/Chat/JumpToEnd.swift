import SwiftUI

/// The way back to the live end of a conversation.
///
/// Shown only when it would do something: there is more transcript than pane, and the
/// reader is not already at the foot of it. No colour — the house rule is that colour
/// means something has gone wrong, and being three screens up a conversation is not
/// something going wrong. New lines arriving while you read are said in words, and
/// so is a question waiting (#723), above or below what is on screen (#973).
struct JumpToEnd: View {
    /// Whether anything has arrived since the reader scrolled away.
    let hasNewBelow: Bool
    /// Whether a question waits on the person out of sight, and then whether it is above
    /// what is on screen rather than below it. The tap goes to it.
    var questionWaiting = false
    var questionAbove = false
    let go: () -> Void

    #if os(iOS)
    private static let touch: CGFloat = 1.4
    #else
    private static let touch: CGFloat = 1
    #endif

    var body: some View {
        Button(action: go) {
            HStack(spacing: 5) {
                Image(systemName: questionWaiting && questionAbove ? "arrow.up" : "arrow.down")
                    // Decorative: a glyph in a capsule, not text (FR-015).
                    .glyph(size: 10, weight: .semibold)
                if let words {
                    Text(words)
                }
            }
            // A thumb, not a pointer, on a touch screen: the same capsule, larger.
            .padding(.horizontal, words != nil ? 12 * Self.touch : 9 * Self.touch)
            .padding(.vertical, 7 * Self.touch)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .appText(.fine)
        .fixedSize()
        .paperRaised(in: .capsule)
        .help(questionWaiting ? "Go to the question waiting \(questionAbove ? "above" : "below")"
              : hasNewBelow ? "Go to the end, where something new is" : "Go to the end")
        .accessibilityLabel(questionWaiting
                            ? "Go to the question waiting \(questionAbove ? "above" : "below") in the conversation"
                            : hasNewBelow ? "Go to the end of the conversation, where something new is"
                            : "Go to the end of the conversation")
    }

    /// A question outranks anything new: it is what the agent is waiting on.
    private var words: String? {
        questionWaiting ? "Question waiting" : hasNewBelow ? "Something new" : nil
    }
}
