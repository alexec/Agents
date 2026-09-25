import AgentsKitCore
import SwiftUI

/// What was said, whatever form it came in.
struct BlocksView: View {
    let blocks: [ContentBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: ContentBlock) -> some View {
        switch block {
        case .text(let text):
            MarkdownText(markdown: text)

        case .image(let data, _, _):
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

        case .resourceLink(_, let name, _, _, _):
            Label(name, systemImage: "doc")
                .appText(.supporting)
                .foregroundStyle(.secondary)

        case .resource(let uri, let text, _, _, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(string: uri)?.lastPathComponent ?? uri)
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                if let text { MarkdownText(markdown: text) }
            }

        case .audio:
            Text("Audio").appText(.supporting).foregroundStyle(.tertiary)

        case .unknown:
            // Kept in the record, not guessed at here.
            Text("Something this version does not know how to show")
                .appText(.fine)
                .foregroundStyle(.tertiary)
        }
    }
}

/// What changed in a file: the old lines against the new ones.
///
/// Red and green would be the obvious thing and this app has one rule about colour,
/// which is that it means something went wrong. So a change is shown by its marks and
/// its weight instead.
struct DiffView: View {
    let diff: ToolCallContent.Diff

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(diff.fileName)
                .appText(.fine)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.mark)
                                .appText(.code)
                                .foregroundStyle(.tertiary)
                            Text(line.text.isEmpty ? " " : line.text)
                                .appText(.code)
                                .foregroundStyle(line.isRemoved ? AnyShapeStyle(.tertiary)
                                                                : AnyShapeStyle(.primary))
                                .strikethrough(line.isRemoved)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 240)
            .paperWell(in: RoundedRectangle(cornerRadius: 8))
        }
        .textSelection(.enabled)
    }

    private struct Line {
        var mark: String
        var text: String
        var isRemoved: Bool
    }

    /// Old lines then new lines. Not a real diff algorithm: the runtimes send the two
    /// sides and what the reader wants is to see both, not to be told which words moved.
    private var lines: [Line] {
        let old = (diff.oldText ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        let new = diff.newText.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [Line] = []
        if diff.oldText != nil, !(old.count == 1 && old[0].isEmpty) {
            lines += old.map { Line(mark: "-", text: String($0), isRemoved: true) }
        }
        if !(new.count == 1 && new[0].isEmpty) {
            lines += new.map { Line(mark: "+", text: String($0), isRemoved: false) }
        }
        return lines
    }
}
