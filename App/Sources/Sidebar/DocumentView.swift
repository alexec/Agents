import AgentsKit
import SwiftUI

/// A markdown file, read as a document rather than as its source.
///
/// Throwaway, on purpose. This is the reading surface and nothing else: it draws
/// through the same `MarkdownText` the conversation uses, so it inherits that
/// renderer's limits — flat lists, no images, `[ ]` where a checkbox belongs. Those
/// come out of the parser, and the parser is not what this is for. What this is for is
/// finding out whether the surface reads as paper before anyone spends a week on the
/// depth underneath it.
///
/// What is real here is `PageMetrics`: the width comes from the pane, the measure and
/// the padding come from the kit, and the page centres itself once the pane is wider
/// than it needs to be.
struct DocumentView: View {
    let text: String
    /// Where the document is, so an image beside it can be found.
    var url: URL?

    var body: some View {
        GeometryReader { geometry in
            let metrics = PageMetrics.forPane(width: geometry.size.width)
            ScrollView(.vertical) {
                MarkdownText(markdown: text, base: url)
                    .frame(maxWidth: metrics.measure, alignment: .leading)
                    .padding(.horizontal, metrics.padding)
                    .padding(.vertical, 24)
                    // The page is centred, not left-hugged, once the pane is wider
                    // than the measure. FR-004: no sheet edge, no shadow, no drawn
                    // border — the paper is the space and the type, because colour is
                    // spoken for.
                    .frame(maxWidth: .infinity)
            }
            // Prose in New York, the system serif, at 12pt. Measured: 13pt gives 57
            // characters at the default pane width and misses SC-003's floor of 60.
            // A relative style rather than a fixed size, so Dynamic Type still moves
            // it (FR-019). Headings, code and chrome stay on the sans and mono faces
            // the rest of the app uses.
            .font(.system(.callout, design: .serif))
            .textSelection(.enabled)
        }
    }
}
