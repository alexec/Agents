import AgentsKit
import SwiftUI

/// What an agent said, read as markdown.
///
/// Agents write markdown whether or not anybody asked them to, and a reply full of
/// backticks and hashes is harder to read than the thing it was describing. Blocks are
/// split in AgentsKit; inline marks are left to the system's own parser.
struct MarkdownText: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownBlock.parse(markdown)) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).textSelection(.enabled)

        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .textSelection(.enabled)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item)
                    }
                }
            }
            .textSelection(.enabled)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        inline(item)
                    }
                }
            }
            .textSelection(.enabled)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().frame(width: 2).foregroundStyle(.quaternary)
                inline(text).foregroundStyle(.secondary)
            }
            .textSelection(.enabled)

        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language).font(.caption2).foregroundStyle(.tertiary)
                }
                // Code keeps its own shape, so it scrolls rather than wraps.
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }

        case .rule:
            Divider()
        }
    }

    /// Bold, code spans and links, through the system's own markdown parser. Text that
    /// will not parse is shown as it was written rather than dropped.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
