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
    /// Somebody's caret, drawn after the last character with their name above it. Only
    /// a live page passes one, for the passage an agent is typing into; everywhere else
    /// this is nil and the text is drawn as it always was.
    var caret: CursorFlag?

    var body: some View {
        if caret != nil {
            content.textRenderer(CaretFlagRenderer())
        } else {
            content
        }
    }

    private var content: AnyView {
        let parsed = MarkdownBlock.parse(markdown)
        // A passage whose first characters have not arrived yet — nothing, or a `#` that
        // is not a heading until its text follows — is still somewhere the caret is.
        if parsed.isEmpty, let caret { return AnyView(caret.caret) }
        return blocks(parsed, caret: caret)
    }

    /// Erased on purpose, and this is the only place it is.
    ///
    /// Blocks nest — a list item holds blocks, a quote holds blocks — so this calls
    /// `view(for:)` and `view(for:)` calls it back. Two mutually recursive `some View`
    /// functions define their opaque types in terms of themselves and do not compile.
    /// One concrete type in the cycle breaks it. A document is tens of blocks, not
    /// thousands, so the cost is not worth a cleverer shape.
    private func blocks(_ blocks: [MarkdownBlock], caret: CursorFlag? = nil) -> AnyView {
        AnyView(stack(blocks, caret: caret))
    }

    @ViewBuilder
    private func stack(_ blocks: [MarkdownBlock], caret: CursorFlag?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Indexed, not keyed by content. Two identical paragraphs are two
            // paragraphs, and a document with two horizontal rules used to hand
            // `ForEach` the same id twice.
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                // The caret is at the end of the text, so it goes to the last block and
                // down into whatever that block holds last.
                view(for: block, caret: index == blocks.count - 1 ? caret : nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, caret: CursorFlag?) -> some View {
        switch block {
        case .paragraph(let text):
            self.text(text, caret: caret).textSelection(.enabled)

        case .heading(let level, let text):
            // Not a step of the scale: `TextStep.heading` says why, and resolves the
            // ladder once for both apps. The consistency check allows it by name.
            self.text(text, caret: caret)
                .font(TextStep.heading(level: level))
                .textSelection(.enabled)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + index, checked: item.checked)
                        // An item holds blocks, because that is what nesting is.
                        blocks(item.blocks, caret: index == items.count - 1 ? caret : nil)
                    }
                }
            }
            .textSelection(.enabled)

        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().frame(width: 2).foregroundStyle(.quaternary)
                blocks(inner, caret: caret).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language).appText(.fine).foregroundStyle(.tertiary)
                }
                // Code keeps its own shape, so it scrolls rather than wraps.
                ScrollView(.horizontal, showsIndicators: false) {
                    self.text(AttributedString(text), caret: caret)
                        .appText(.code)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .paperWell(in: RoundedRectangle(cornerRadius: 8))
            }

        case .image(let source, let alt):
            trailed(image(source: source, alt: alt), by: caret)

        case .table(let table):
            // Columns keep their width, so a wide table scrolls rather than
            // squeezing its text into a stack of single words.
            trailed(ScrollView(.horizontal, showsIndicators: false) {
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
            .textSelection(.enabled), by: caret)

        case .rule:
            trailed(Divider(), by: caret)
        }
    }

    /// A block's text, with the caret after its last character when there is one.
    private func text(_ text: AttributedString, caret: CursorFlag?) -> Text {
        guard let caret else { return Text(text) }
        return Text("\(Text(text))\(caret.caret)")
    }

    /// A block that is not text — a picture, a table, a rule — with the caret on the
    /// line after it, which is where the next character typed would go.
    @ViewBuilder
    private func trailed<Content: View>(_ content: Content, by caret: CursorFlag?) -> some View {
        if let caret {
            VStack(alignment: .leading, spacing: 4) {
                content
                caret.caret
            }
        } else {
            content
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
