import AgentsKitCore
import SwiftUI

/// A runtime's sandbox that could not be set up (064, look): what happened, on the record.
/// While the agent waits on an answer (`Agent.pendingSandboxFailure`), the answers are an Ask
/// at the end of the chat (`SandboxAsk`, #5031), not here; the note after it says what was chosen.
struct SandboxFailureCard: View {
    let record: SandboxFailureRecord
    @Environment(\.chatActions) private var actions
    @Environment(\.orgSandboxSetBy) private var setBy
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
                        .togglesFold($showsDetail)
                }
            }
            if !isWaiting, !record.recoveryOffered {
                Text(record.recoveryOffered
                     ? SandboxWords.cardOffer(runtimeID: record.runtimeID, name: name,
                                              afterTools: record.completedToolCalls > 0)
                     : SandboxWords.noRecovery)
                    .appText(.reading)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Continue without sandbox is not offered: the organisation requires it (#998).
            if let setBy { OrgPolicyLine(mark: setBy) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.warning.color?.opacity(0.03) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.warning.color ?? .secondary).opacity(0.25)))
    }
}

/// The sandbox failure the agent waits on (#253), as an Ask (#5031): Keep stopped on the left,
/// Continue without sandbox the primary. The window and the Remote draw it under "Waiting for
/// you"; the web page's is `SandboxAsk` in `Rows.tsx`.
struct SandboxAsk: View {
    let record: SandboxFailureRecord
    /// The organisation's mark while its policy requires the sandbox (#998): no Continue.
    let setBy: DaemonAPI.PolicySetBy?
    let keepStopped: () async -> Void
    let continueWithout: (() async -> Void)?
    @State private var showsDetail = false
    @State private var isSending = false

    private var name: String { RuntimeCatalog.runtime(id: record.runtimeID)?.name ?? record.runtimeID }
    private var offered: Bool { record.recoveryOffered && setBy == nil && continueWithout != nil }

    var body: some View {
        AskCard(icon: "exclamationmark.triangle", title: SandboxWords.cardTitle(name)) {
            Text(record.recoveryOffered
                 ? SandboxWords.cardOffer(runtimeID: record.runtimeID, name: name,
                                          afterTools: record.completedToolCalls > 0)
                 : SandboxWords.noRecovery)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !record.detail.isEmpty {
                DisclosureGroup(isExpanded: $showsDetail) {
                    Text(record.detail)
                        .appText(.code)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Show error details").appText(.fine).foregroundStyle(.secondary)
                        .togglesFold($showsDetail)
                }
            }
            if let setBy { OrgPolicyLine(mark: setBy) }
        } decline: {
            if offered {
                AskDecline(SandboxWords.keepStopped) { send(keepStopped) }
                    .disabled(isSending)
            }
        } buttons: {
            if offered, let continueWithout {
                Button(SandboxWords.continueWithout) { send(continueWithout) }
                    .buttonStyle(.paperProminent)
                    .disabled(isSending)
            } else {
                Button(SandboxWords.keepStopped) { send(keepStopped) }
                    .buttonStyle(.paperProminent)
                    .disabled(isSending)
            }
        }
    }

    private func send(_ action: @escaping () async -> Void) {
        isSending = true
        Task {
            await action()
            isSending = false
        }
    }
}
