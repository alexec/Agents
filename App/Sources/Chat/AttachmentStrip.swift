import AgentsKit
import SwiftUI

/// What is going with the next prompt, above the field, each with a way to take it off.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    let refusal: (Attachment) -> String?
    let remove: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: attachment))
                            // Decorative: a glyph in a badge, not text (FR-015).
                            .font(.system(size: 10))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.displayName)
                                .lineLimit(1)
                            if let refusal = refusal(attachment) {
                                // Said before it is sent, not after.
                                Text(refusal).appText(.fine).tinted(.failure)
                            }
                        }
                        Button {
                            remove(attachment)
                        } label: {
                            Image(systemName: "xmark")
                                // Decorative: a glyph in a badge, not text (FR-015).
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .appText(.supporting)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .help(attachment.displayName)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 34)
    }

    private func symbol(for attachment: Attachment) -> String {
        switch attachment.block {
        case .image: return "photo"
        case .audio: return "waveform"
        case .resource: return "doc.text"
        default: return "doc"
        }
    }
}

/// Files under the agent's folders, offered while `@` is being typed.
struct MentionList: View {
    let mentions: [FileMention]
    let selected: Int
    let choose: (FileMention) -> Void

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(mentions.enumerated()), id: \.element.id) { index, mention in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(mention.name).appText(.supporting)
                            Text(mention.relativePath)
                                .appText(.fine)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(index == selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .id(index)
                        .onTapGesture { choose(mention) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
            .onChange(of: selected) { scroller.scrollTo(selected, anchor: .center) }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }
}
