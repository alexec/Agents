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
/// A workflow waiting for an OK is asked the same way, by its file's path (#569). A folder's
/// policy (#2957, frame D) says which rules it makes looser, and asks **Allow**, **Keep
/// <old value>** or **Show Change**.
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
        // An Ask (#5031): who changed what as the title, the counts where the asker goes,
        // Review… on the left, Undo and Keep on the right.
        AskCard(icon: "doc.text", title: change.headline, asker: counts) {
            // A folder's policy (#2957, frame D): which rules the change makes looser.
            if let policy = change.policy {
                Text(policy.words)
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } decline: {
            AskDecline(change.policy == nil ? "Review…" : "Show Change", action: review)
        } buttons: {
            Group {
                Button(change.policy?.keepTitle ?? "Undo") { answer(keep: false) }
                    .buttonStyle(.paper)
                Button(change.policy == nil ? "Keep" : "Approve") { answer(keep: true) }
                    .buttonStyle(.paperProminent)
            }
            .disabled(reading == nil || busy || isOffline)
        }
        .accessibilityLabel(change.question)
        .task(id: change) {
            reading = await read()
        }
    }

    /// +12 −3, or nil while the change is read.
    private var counts: String? {
        guard let counts = reading?.counts else { return nil }
        return "+\(counts.added) −\(counts.removed)"
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
