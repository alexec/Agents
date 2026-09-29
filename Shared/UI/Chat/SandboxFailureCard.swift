import AgentsKitCore
import SwiftUI

/// A runtime's sandbox that could not be set up (064, wireframes): what happened, what
/// **Continue without sandbox** would change, and the two answers. Once answered it is a
/// line saying what the person chose.
struct SandboxFailureCard: View {
    let record: SandboxFailureRecord
    @Environment(\.chatActions) private var actions
    @State private var showsDetail = false
    @State private var isSending = false

    private var name: String { RuntimeCatalog.runtime(id: record.runtimeID)?.name ?? record.runtimeID }

    var body: some View {
        switch record.resolution {
        case .continued:
            Text("Carried on without \(name)’s sandbox.").appText(.reading).foregroundStyle(.secondary)
        case .keptStopped:
            Text("\(SandboxWords.cardTitle(name)). Kept stopped.").appText(.reading).foregroundStyle(.secondary)
        case .pending:
            card
        }
    }

    private var card: some View {
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
            Text(record.recoveryOffered
                 ? SandboxWords.cardOffer(runtimeID: record.runtimeID, name: name,
                                          afterTools: record.completedToolCalls > 0)
                 : SandboxWords.noRecovery)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.attention.color?.opacity(0.07) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.attention.color ?? .secondary).opacity(0.25)))
    }
}
