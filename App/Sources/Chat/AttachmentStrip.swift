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
                    .paperRaised(in: .capsule)
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
