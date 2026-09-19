import AgentsKit
import SwiftUI

/// A message, drawn block by block.
///
/// Text goes through the markdown renderer, because agents write markdown whether or
/// not anybody asked. A picture is drawn as a picture: 001 turned one into an empty
/// line, which is what happens when a message is flattened to its text.
struct BlocksView: View {
    let blocks: [ContentBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label("A picture this Mac cannot draw", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .audio:
            Label("Audio", systemImage: "waveform")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .resourceLink(let uri, let name, _, _, _):
            Button {
                if let url = URL(string: uri) { NSWorkspace.shared.open(url) }
            } label: {
                Label(name, systemImage: "doc")
                    .font(.footnote)
            }
            .buttonStyle(.link)

        case .resource(let uri, let text, _, _, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(string: uri)?.lastPathComponent ?? uri)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let text { MarkdownText(markdown: text) }
            }

        case .unknown(let raw):
            // Kept rather than dropped, and shown as what it is.
            Text(raw["type"]?.stringValue.map { "Something this app does not draw yet: \($0)" }
                 ?? "Something this app does not draw yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
