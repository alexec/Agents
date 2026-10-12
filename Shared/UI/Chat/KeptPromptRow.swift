import AgentsKitCore
import SwiftUI

/// A prompt the control plane keeps until its stopped workspace is up (#691 US3, layouts.md
/// L6): the queued bubble of #95, with what it waits for under it and ×, or, once the start
/// failed, why it wasn't sent and **Try Again**.
///
/// The same row stands for a kept start, under the New Agent prompt, whose agent isn't made yet.
struct KeptPromptRow: View {
    @Environment(\.chatActions) private var actions
    let kept: DaemonAPI.KeptRequest

    var body: some View {
        let line = OfflineWords.keptLine(name: actions.hostName(kept.host), kept: kept)
        VStack(alignment: .trailing, spacing: 2) {
            Text(kept.text)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(12)
                .paperWell(in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                // One element, so the label never sits over a child's (stacked labels crash AppKit).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(line): \(kept.text)")

            HStack(spacing: 12) {
                Text(line)
                    .appText(.supporting)
                    .foregroundStyle((kept.failed == nil ? StateTint.none : .attention).style(or: .secondary))
                if kept.failed != nil {
                    Button("Try Again") { Task { await actions.retryKept(kept) } }
                        .buttonStyle(.borderless)
                        .appText(.supporting)
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                }
                Button {
                    Task { await actions.dropKept(kept) }
                } label: {
                    Image(systemName: "xmark")
                        .appText(.supporting)
                        .frame(width: 18, height: 18)
                        #if os(iOS)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                        #endif
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Do not send this")
                .accessibilityLabel("Remove kept prompt")
            }
        }
        .padding(.leading, 60)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
