import AgentsKitCore
import SwiftUI

/// A runtime's sandbox that could not be set up (064, look): what happened, what
/// **Continue without sandbox** would change, and the two answers while the card waits.
/// The chat passes the answers only then (`Agent.pendingSandboxFailure`); an answered or
/// superseded card keeps saying what happened, and the note after it says what was chosen.
struct SandboxFailureCard: View {
    let record: SandboxFailureRecord
    @Environment(\.chatActions) private var actions
    @State private var showsDetail = false
    @State private var isSending = false

    private var name: String { RuntimeCatalog.runtime(id: record.runtimeID)?.name ?? record.runtimeID }

    /// Waiting for an answer: this is the open agent's waiting card.
    private var isWaiting: Bool { actions.keepStopped != nil && actions.waitingSandbox == record }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SandboxWords.cardTitle(name))
                .appText(.reading).fontWeight(.semibold)
            Text(SandboxWords.cardBody(runtimeID: record.runtimeID, name: name, hang: record.hang))
                .appText(.reading)
            if !record.detail.isEmpty {
                DisclosureGroup(isExpanded: $showsDetail) {
                    Text(record.detail)
                        .appText(.code)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Show error details").appText(.reading).foregroundStyle(.secondary)
                }
            }
            if isWaiting || !record.recoveryOffered {
                Text(record.recoveryOffered
                     ? SandboxWords.cardOffer(runtimeID: record.runtimeID, name: name,
                                              afterTools: record.completedToolCalls > 0)
                     : SandboxWords.noRecovery)
                    .appText(.reading)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isWaiting { answers }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.attention.color?.opacity(isWaiting ? 0.07 : 0.03) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.attention.color ?? .secondary).opacity(0.25)))
    }

    private var answers: some View {
        HStack(spacing: 10) {
            Spacer()
            if let keepStopped = actions.keepStopped {
                Button(SandboxWords.keepStopped) { Task { await keepStopped() } }
            }
            if record.recoveryOffered, let go = actions.continueWithoutSandbox {
                Button(SandboxWords.continueWithout) {
                    isSending = true
                    Task { await go(); isSending = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending)
            }
        }
    }
}
