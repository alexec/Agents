import AgentsKitCore
import SwiftUI

/// What the open agent holds and waits for, at the foot of its chat with the working line
/// (036 FR-010, #2344): one line each, "▣ Screen · 18 min" or "◷ Waiting for Screen ·
/// held by “Fix login” until 14:12 · 2nd".
///
/// It says what the agent is doing now, as the working line does, so it is not above the
/// prompt, where all is for the person to act on, and nobody can act on a lease (FR-012).
/// One view for both apps, so the Mac and the phone say the same words. Nothing is
/// tinted: holding or waiting is neither a person being needed nor anything broken.
///
/// `open` is each app's: the Mac opens Resources at the resource, the Remote its
/// Resources page. Nil draws the words alone. With it, each line ends in a chevron, so it
/// reads as a way somewhere, and its hit area is a full row: 44 pt high on iOS (#2448).
struct LeaseLine: View {
    let status: LeaseStatus
    var open: ((ResourceName) -> Void)?

    private var lines: [(name: ResourceName, text: String)] {
        zip(status.holding.map(\.name) + status.waiting.map(\.name), status.lines).map { ($0, $1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: open == nil ? 4 : 0) {
            ForEach(lines, id: \.text) { line in
                if let open {
                    Button { open(line.name) } label: {
                        HStack(spacing: 4) {
                            words(line.text)
                            Image(systemName: "chevron.right")
                                .appText(.fine)
                                .imageScale(.small)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: Self.rowHeight)
                        .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .help(status.fullLine)
                } else {
                    words(line.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.fullLine)
    }

    #if os(iOS)
    private static let rowHeight: CGFloat = 44
    #else
    private static let rowHeight: CGFloat = 22
    #endif

    private func words(_ text: String) -> some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentShape(Rectangle())
    }
}
