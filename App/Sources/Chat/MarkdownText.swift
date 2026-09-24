import AgentsKit
import SwiftUI

/// Markdown, drawn.
///
/// Used twice: for what an agent said in the conversation, and for a document in the
/// files pane. The blocks are split in AgentsKit, where tests can reach the decision;
/// what each one looks like is here.
///
/// Inline marks arrive as attributes on the text, from the same parse that found the
/// blocks. Nothing here parses anything.
struct MarkdownText: View {
    let markdown: String
    /// The document's own location, when there is one, so a relative image can be
    /// found. Nil in the conversation, where there is no document to be relative to —
    /// and an image then shows its alternative text rather than being fetched (FR-013).
    var base: URL?

    var body: some View {
        blocks(MarkdownBlock.parse(markdown))
    }

    /// Erased on purpose, and this is the only place it is.
    ///
    /// Blocks nest — a list item holds blocks, a quote holds blocks — so this calls
    /// `view(for:)` and `view(for:)` calls it back. Two mutually recursive `some View`
    /// functions define their opaque types in terms of themselves and do not compile.
    /// One concrete type in the cycle breaks it. A document is tens of blocks, not
    /// thousands, so the cost is not worth a cleverer shape.
    private func blocks(_ blocks: [MarkdownBlock]) -> AnyView {
        AnyView(stack(blocks))
    }

    @ViewBuilder
    private func stack(_ blocks: [MarkdownBlock]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Indexed, not keyed by content. Two identical paragraphs are two
            // paragraphs, and a document with two horizontal rules used to hand
            // `ForEach` the same id twice.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text).textSelection(.enabled)

        case .heading(let level, let text):
            // Not a step of the scale: `TextStep.heading` says why, and resolves the
            // ladder once for both apps. The consistency check allows it by name.
            Text(text)
                .font(TextStep.heading(level: level))
                .textSelection(.enabled)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + index, checked: item.checked)
                        // An item holds blocks, because that is what nesting is.
                        blocks(item.blocks)
                    }
                }
            }
            .textSelection(.enabled)

        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().frame(width: 2).foregroundStyle(.quaternary)
                blocks(inner).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language).appText(.fine).foregroundStyle(.tertiary)
                }
                // Code keeps its own shape, so it scrolls rather than wraps.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .appText(.code)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }

        case .image(let source, let alt):
            image(source: source, alt: alt)

        case .table(let table):
            // Columns keep their width, so a wide table scrolls rather than
            // squeezing its text into a stack of single words.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                            Text(cell)
                                .appText(.supporting).fontWeight(.semibold)
                                .gridColumnAlignment(columnAlignment(table, index))
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell).appText(.supporting)
                            }
                        }
                    }
                }
                .padding(2)
            }
            .textSelection(.enabled)

        case .rule:
            Divider()
        }
    }

    /// What goes in front of a list item: a number, a box, or a bullet.
    ///
    /// The box is drawn and never tapped. The pane is read-only, and a checkbox that
    /// looks pressable but is not would be a worse lie than one that plainly is not.
    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if ordered {
            Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
        } else {
            Text("•").foregroundStyle(.secondary)
        }
    }

    /// An image in a document, found beside the document.
    ///
    /// Only from disk, and only from under the folder the document is in. Nothing here
    /// makes a network request on a document's behalf (FR-011), so a remote image is
    /// its alternative text — which is what alternative text is for.
    @ViewBuilder
    private func image(source: String, alt: String) -> some View {
        // A file beside the document, inside its folder tree, and nothing else: no
        // address on the network and no path that climbs out (022 FR-019). Anything
        // refused here shows its alternative text below, as it always has.
        if let base,
           let url = URL(string: source, relativeTo: base)?.standardizedFileURL,
           url.isFileURL,
           url.path.hasPrefix(base.deletingLastPathComponent().standardizedFileURL.path),
           let loaded = Self.image(at: url) {
            Image(nsImage: loaded)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "photo").foregroundStyle(.tertiary)
                Text(alt.isEmpty ? source : alt).foregroundStyle(.secondary)
            }
            .appText(.supporting)
        }
    }

    /// Decoded once per file. `body` runs whenever the page redraws — a passage
    /// being marked, say — and reading the picture off the disk each time was the
    /// one slow thing on a page of text.
    private static let images = NSCache<NSURL, NSImage>()

    private static func image(at url: URL) -> NSImage? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard let loaded = NSImage(contentsOf: url) else { return nil }
        images.setObject(loaded, forKey: url as NSURL)
        return loaded
    }

    /// What the dashes under the header said about this column.
    private func columnAlignment(_ table: MarkdownBlock.Table, _ index: Int) -> HorizontalAlignment {
        guard table.columns.indices.contains(index) else { return .leading }
        switch table.columns[index] {
        case .leading: return .leading
        case .centre: return .center
        case .trailing: return .trailing
        }
    }
}
