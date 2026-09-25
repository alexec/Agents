import AgentsKitCore
import SwiftUI

/// What the open agent holds and waits for, above the prompt bar (036 FR-010): one
/// capsule each, "▣ Screen · 18 min" or "◷ Waiting for Screen · held by “Fix login”
/// until 14:12 · 2nd".
///
/// One view for both apps, so the Mac and the phone say the same words. It wraps
/// rather than scrolling sideways, because a capsule half off the edge of a phone is a
/// lease nobody can see. Nothing is tinted: holding or waiting is neither a person
/// being needed nor anything broken.
///
/// `open` is each app's. The Mac opens Resources at the resource. Without it — the
/// phone, where Resources is not (FR-011) — a tap shows the whole line in a small sheet
/// that only reads.
struct LeaseRow: View {
    let status: LeaseStatus
    var open: ((ResourceName) -> Void)?
    @State private var isShowingLine = false

    private var capsules: [(name: ResourceName, text: String)] {
        zip(status.holding.map(\.name) + status.waiting.map(\.name), status.capsules).map { ($0, $1) }
    }

    var body: some View {
        WrappingHStack(spacing: 8) {
            ForEach(capsules, id: \.text) { capsule in
                Button {
                    if let open { open(capsule.name) } else { isShowingLine = true }
                } label: {
                    Text(capsule.text)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .paperRaised(in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(status.fullLine)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.fullLine)
        .sheet(isPresented: $isShowingLine) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Resources").appText(.reading).fontWeight(.semibold)
                ForEach(status.fullLine.components(separatedBy: ". "), id: \.self) { sentence in
                    Text(sentence.hasSuffix(".") ? sentence : sentence + ".")
                        .appText(.supporting)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .presentationDetents([.medium])
            .paperSheet()
        }
    }
}
