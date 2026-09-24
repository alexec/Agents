import AgentsKitCore
import SwiftUI

/// What an agent said, read as markdown.
///
/// Agents write markdown whether or not anybody asked them to. The reading is done in
/// `AgentsKitCore` — the same parser the Mac uses, so the two never disagree about
/// where a fence ended — and the text payloads arrive already parsed, so nothing here
/// parses anything a second time.
///
/// Laid out for a narrow screen. Code and tables scroll sideways rather than wrapping,
/// because code folded at 390 points is code nobody can read, and nesting is drawn as
/// indentation rather than as a second column there is no room for.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        BlockStack(blocks: MarkdownBlock.parse(markdown))
    }
}

/// A run of blocks, at whatever depth. Recursive, because so is the document: a list
/// item holds blocks, and one of them can be another list.
private struct BlockStack: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            // Not a step of the scale: `TextStep.heading` says why, and resolves the
            // ladder once for both apps. The consistency check allows it by name.
            Text(text)
                .font(TextStep.heading(level: level))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(ordered: ordered, number: start + index, checked: item.checked)
                        BlockStack(blocks: item.blocks)
                    }
                }
            }

        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().frame(width: 2).foregroundStyle(.quaternary)
                BlockStack(blocks: inner).foregroundStyle(.secondary)
            }

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

        case .table(let table):
            // Columns keep their width, so a wide table scrolls rather than squeezing
            // its text into a stack of single words.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                            Text(cell)
                                .appText(.supporting).fontWeight(.semibold)
                                .gridColumnAlignment(alignment(table, index))
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

        case .image(let source, let alt):
            // Named, not fetched. The image is on the Mac or behind a URL, and a
            // remote that went and got it would be reaching past the mailbox.
            Label(alt.isEmpty ? URL(string: source)?.lastPathComponent ?? source : alt,
                  systemImage: "photo")
                .appText(.supporting)
                .foregroundStyle(.secondary)

        case .rule:
            Divider()
        }
    }

    /// What goes in front of a list item: a bullet, its number, or its checkbox.
    @ViewBuilder
    private func marker(ordered: Bool, number: Int, checked: Bool?) -> some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square" : "square")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else if ordered {
            Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
        } else {
            Text("•").foregroundStyle(.secondary)
        }
    }

    /// What the dashes under the header said about this column.
    private func alignment(_ table: MarkdownBlock.Table, _ index: Int) -> HorizontalAlignment {
        guard table.columns.indices.contains(index) else { return .leading }
        switch table.columns[index] {
        case .leading: return .leading
        case .centre: return .center
        case .trailing: return .trailing
        }
    }
}
