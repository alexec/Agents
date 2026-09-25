import AgentsKitCore
import SwiftUI

/// Markdown, drawn, the same on the Mac and the phone (034).
///
/// Used twice: for what an agent said in the conversation, and for a document on a
/// live page. The blocks are split in AgentsKitCore, where tests can reach the
/// decision; what each one looks like is here. There were two of these, one per app,
/// and they had drifted: the phone's drew no pictures and no caret, the Mac's had never
/// been told a paragraph must not be cut off at a narrow width. This is both.
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
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            // Not a step of the scale: `TextStep.heading` says why, and resolves the
            // ladder once for both apps. The consistency check allows it by name.
            self.text(text, caret: caret)
                .font(TextStep.heading(level: level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
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
    /// A file beside the document, inside its folder tree, and nothing else: no
    /// address on the network and no path that climbs out (022 FR-019). Nothing here
    /// makes a network request on a document's behalf (FR-011), so a remote image is
    /// its alternative text — which is what alternative text is for. How the file is
    /// read is the app's: the Mac's disk, or the phone asking the Mac.
    @ViewBuilder
    private func image(source: String, alt: String) -> some View {
        if let base, let url = ImageStamps.url(of: source, base: base) {
            PagePicture(url: url, source: source, alt: alt)
        } else {
            PictureAlternative(source: source, alt: alt)
        }
    }

    /// Lists sit a little looser on a touch screen, where a line is a target.
    #if os(macOS)
    private static let itemSpacing: CGFloat = 4
    #else
    private static let itemSpacing: CGFloat = 6
    #endif

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

/// A picture on the page, read through the app (034).
///
/// Loaded once per identity. The page gives a passage a new identity when its
/// picture's file changes, which is what makes this read it again.
private struct PagePicture: View {
    @Environment(\.pageActions) private var actions
    let url: URL
    let source: String
    let alt: String

    @State private var loaded: PlatformImage?
    @State private var tried = false

    var body: some View {
        Group {
            if let loaded {
                Image(platformImage: loaded)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(alt.isEmpty ? "Image" : alt)
            } else if tried {
                PictureAlternative(source: source, alt: alt)
            } else {
                // Held open while it loads, so the words below do not jump twice.
                Color.clear.frame(height: 24)
            }
        }
        .task(id: url) {
            loaded = await actions.image(url)
            tried = true
        }
    }
}

/// A picture that cannot be drawn: its alternative text, or its name.
private struct PictureAlternative: View {
    let source: String
    let alt: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "photo").foregroundStyle(.tertiary)
            Text(alt.isEmpty ? URL(string: source)?.lastPathComponent ?? source : alt)
                .foregroundStyle(.secondary)
        }
        .appText(.supporting)
    }
}
