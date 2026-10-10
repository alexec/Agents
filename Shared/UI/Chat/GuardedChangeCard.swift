import AgentsKitCore
import SwiftUI

/// A change to one of the app's own files in `.agents`, made outside the app (#502), as
/// the question the window and the Remote both ask (#531): who made it, what changed line
/// by line, and Keep or Undo. Until then the app goes on with the copy last approved.
///
/// Asked in the session of the agent that made it, over the prompt as a form is, or on
/// the project's page when no agent did; and in Project Settings on the Mac. The client
/// says how to read the change and how to answer it, so the card holds no model of its own.
/// A workflow waiting for an OK is asked the same way, by its file's path (#569).
struct GuardedChangeCard: View {
    let change: GuardedChange
    /// What the file was and is; nil when it could not be read, which the client has said.
    let read: () async -> GuardedChangeReading?
    /// Keep (true) or Undo (false), of the file as it was read.
    let settle: (GuardedChangeReading, Bool) async -> Void
    var isOffline = false

    @State private var reading: GuardedChangeReading?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(change.headline, systemImage: "exclamationmark.shield")
                .appText(.reading).fontWeight(.semibold)
                .tinted(.attention)
            Text(change.explanation)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reading {
                ScrollView {
                    diff(reading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Undo") { answer(keep: false) }
                    .buttonStyle(.paper)
                Button("Keep") { answer(keep: true) }
                    .buttonStyle(.paperProminent)
            }
            .disabled(reading == nil || busy || isOffline)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.attention.color?.opacity(0.07) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.attention.color ?? .secondary).opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(change.question)
        .task(id: change) {
            reading = await read()
        }
    }

    private func diff(_ reading: GuardedChangeReading) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(reading.lines.enumerated()), id: \.offset) { _, line in
                Text(Self.mark(line.kind) + line.text)
                    .appText(.code)
                    .foregroundStyle(Self.style(line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Paper.ground))
    }

    /// The colours Changes draws a removed and an added file in (`ChangeTint`); the
    /// mark beside each line says it without them.
    private static func style(_ kind: GuardedDiffLine.Kind) -> AnyShapeStyle {
        switch kind {
        case .same: AnyShapeStyle(.secondary)
        case .removed: AnyShapeStyle(ChangeTint.color(.deleted))
        case .added: AnyShapeStyle(ChangeTint.color(.added))
        }
    }

    private static func mark(_ kind: GuardedDiffLine.Kind) -> String {
        switch kind {
        case .same: "  "
        case .removed: "− "
        case .added: "+ "
        }
    }

    private func answer(keep: Bool) {
        guard let reading else { return }
        busy = true
        Task {
            await settle(reading, keep)
            busy = false
        }
    }
}
