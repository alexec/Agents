import AgentsKitCore
import SwiftUI

/// A change to one of the app's own files in `.agents`, made outside the app (#502), as
/// the question the window and the Remote both ask (#531): who made it, how many lines
/// changed, Review… for the whole change on its own page (#1472), and Keep or Undo for a
/// quick answer. Until then the app goes on with the copy last approved.
///
/// Asked in the session of the agent that made it, over the prompt as a form is, or on
/// the folder's page when no agent did; and in Folder Settings on the Mac. The client
/// says how to read the change and how to answer it, so the card holds no model of its own.
/// A workflow waiting for an OK is asked the same way, by its file's path (#569).
struct GuardedChangeCard: View {
    let change: GuardedChange
    /// What the file was and is; nil when it could not be read, which the client has said.
    let read: () async -> GuardedChangeReading?
    /// Keep (true) or Undo (false), of the file as it was read.
    let settle: (GuardedChangeReading, Bool) async -> Void
    /// Opens the change's Review page (#1472).
    let review: () -> Void
    var isOffline = false

    @State private var reading: GuardedChangeReading?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(change.headline, systemImage: "exclamationmark.shield")
                .appText(.reading).fontWeight(.semibold)
                .tinted(.attention)
            HStack(spacing: 10) {
                if let counts = reading?.counts {
                    Text("+\(counts.added) −\(counts.removed)")
                        .appText(.fine)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(counts.added) lines added, \(counts.removed) removed")
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Review…", action: review)
                    .buttonStyle(.paper)
                Group {
                    Button("Undo") { answer(keep: false) }
                        .buttonStyle(.paper)
                    Button("Keep") { answer(keep: true) }
                        .buttonStyle(.paperProminent)
                }
                .disabled(reading == nil || busy || isOffline)
            }
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

    private func answer(keep: Bool) {
        guard let reading else { return }
        busy = true
        Task {
            await settle(reading, keep)
            busy = false
        }
    }
}
