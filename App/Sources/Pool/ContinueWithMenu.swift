import AgentsKit
import SwiftUI

/// The runtime a chat could carry on with (052), as a submenu of the model pill: the
/// per-chat switch, the pool's runtimes with their states, and every other runtime under
/// a rule. Picking one opens the Continue with sheet; nothing moves until that is confirmed.
struct ContinueWithItems: View {
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
        Menu("Continue with") {
            Toggle("Carry on when \(PoolWords.runtimeName(agent.runtimeID)) runs out", isOn: Binding(
                get: { !agent.switchingOff },
                set: { isOn in Task { await model.setSwitching(agent.id, isOn: isOn) } }))
            Divider()
            ForEach(rows) { row in
                Button {
                    model.continuingWith = ContinueWith(agentID: agent.id, entry: row.entry)
                } label: {
                    if row.state.isOut || row.unusable != nil {
                        Text(PoolWords.runtimeName(row.entry.runtimeID))
                        Text(row.line(now: model.poolStatus?.at ?? .now))
                    } else {
                        Text(PoolWords.runtimeName(row.entry.runtimeID))
                    }
                }
            }
            if !others.isEmpty {
                Section("Not in the pool") {
                    ForEach(others) { status in
                        Button(status.runtime.name) {
                            model.continuingWith = ContinueWith(
                                agentID: agent.id,
                                entry: PoolEntry(runtimeID: status.runtime.id, payment: .allowance(label: nil)))
                        }
                    }
                }
            }
        }
    }
}

/// A chat the person is moving by hand, and where to (US5).
struct ContinueWith: Identifiable, Hashable {
    let agentID: UUID
    var entry: PoolEntry
    /// Changing what an automatic switch carried on with, on the runtime it is on (FR-029).
    var adjust = false
    var id: String { "\(agentID)-\(entry.id)-\(adjust)" }
}
