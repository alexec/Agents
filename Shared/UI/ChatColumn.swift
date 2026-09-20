import AgentsKitCore
import SwiftUI

/// The chat's column: a measure that is a ceiling, not a gutter.
///
/// Everything that sits in the conversation's column — the transcript, the floating
/// prompt bar, a permission or elicitation card above it, and the project page that
/// holds the same bar — draws its horizontal edges from this and from nothing else, so
/// the edges cannot be changed independently and drift apart (FR-021). The arithmetic
/// is `ChatMetrics`, in the kit where a test holds it; this only applies it.
extension View {
    /// Fits the view to the chat column for a pane of the given width: padded by the
    /// measure's margin, capped at the measure, and centred so the surplus splits
    /// either side (FR-020). The ceiling is on the column, not on the content, so
    /// larger accessibility text reflows within it rather than being clipped (FR-022).
    func chatColumn(paneWidth: Double) -> some View {
        let metrics = ChatMetrics.forPane(width: paneWidth)
        return self
            .padding(.horizontal, metrics.padding)
            .frame(maxWidth: metrics.measure + metrics.padding * 2)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The same, measuring the pane itself.
    ///
    /// The modifier's outer frame takes whatever width it is offered, which in a
    /// vertical scroll view, a `ZStack` filling the pane, or the detail column is the
    /// pane's width; the column is worked out from that. Every surface in the column
    /// measures the same pane, so they agree without being handed a number.
    func chatColumn() -> some View {
        modifier(ChatColumnModifier())
    }
}

private struct ChatColumnModifier: ViewModifier {
    @State private var paneWidth: Double = 0

    func body(content: Content) -> some View {
        // Before the first layout pass the width is unknown. Unconstrained for that
        // pass rather than squeezed to nothing: `forPane(0)` would give a column of
        // zero and a frame of text flashing empty.
        let metrics = paneWidth > 0 ? ChatMetrics.forPane(width: paneWidth) : nil
        content
            .padding(.horizontal, metrics?.padding ?? ChatMetrics.widePadding)
            .frame(maxWidth: metrics.map { $0.measure + $0.padding * 2 } ?? .infinity)
            .frame(maxWidth: .infinity, alignment: .center)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { paneWidth = $0 }
    }
}
