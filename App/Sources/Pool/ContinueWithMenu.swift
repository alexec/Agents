import AgentsKit
import SwiftUI

/// The runtime control on a chat's prompt bar (052, wireframes §2): the per-chat
/// switch, the pool's runtimes with their states, and every other runtime under a rule.
/// Picking one opens the Continue with sheet; nothing moves until that is confirmed.
struct ContinueWithMenu: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    private var rows: [PoolStatus.Row] {
        (model.poolStatus?.rows ?? []).filter { $0.entry.runtimeID != agent.runtimeID }
    }

    private var others: [RuntimeStatus] {
        let pooled = Set(model.poolStatus?.rows.map(\.entry.runtimeID) ?? [])
        return model.availableRuntimes.filter { $0.runtime.id != agent.runtimeID && !pooled.contains($0.runtime.id) }
    }

    var body: some View {
        SelectCapsule(name: "Runtime", title: PoolWords.runtimeName(agent.runtimeID)) { dismiss in
            SelectChoice(title: "Carry on when \(PoolWords.runtimeName(agent.runtimeID)) runs out",
                         description: nil, isChosen: true) { dismiss() }
            Divider().padding(.vertical, 4)
            Text("CONTINUE WITH").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            ForEach(rows) { row in
                SelectChoice(title: PoolWords.runtimeName(row.entry.runtimeID),
                             description: row.state.isOut || row.unusable != nil
                                ? row.line(now: model.poolStatus?.at ?? .now) : nil,
                             isChosen: false) {
                    dismiss()
                    model.continuingWith = ContinueWith(agentID: agent.id, entry: row.entry)
                }
            }
            if !others.isEmpty {
                Divider().padding(.vertical, 4)
                ForEach(others) { status in
                    SelectChoice(title: status.runtime.name, description: "not in the pool", isChosen: false) {
                        dismiss()
                        model.continuingWith = ContinueWith(
                            agentID: agent.id,
                            entry: PoolEntry(runtimeID: status.runtime.id, payment: .allowance(label: nil)))
                    }
                }
            }
            Text("Runtimes that are out can still be picked.")
                .appText(.fine).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4)
        }
        .help("Carry this chat on with another runtime")
    }
}

/// A chat the person is moving by hand, and where to (US5).
struct ContinueWith: Identifiable, Hashable {
    let agentID: UUID
    let entry: PoolEntry
    var id: String { "\(agentID)-\(entry.id)" }
}
