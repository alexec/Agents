import AgentsKit
import SwiftUI

/// Settings ▸ Pool (052, US2; wireframes §4): the switch, the entries in the order to
/// try, a fallback model per entry, and the two ways to add one. Allowances come from
/// the runtimes that are installed and signed in; a key has its own sheet and can only
/// be free or prepaid credit (FR-001a).
struct PoolSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isAddingCredit = false
    @State private var refusal: String?

    private var pool: PoolSettings { model.poolStatus?.settings ?? PoolSettings() }

    /// Runtimes that can be added as an allowance: installed, signed in, and on a
    /// sign-in rather than a key. Gemini runs only on a key, so it is added as credit.
    private var addable: [RuntimeStatus] {
        let inPool = Set(pool.entries.filter { !$0.isKeyed }.map(\.runtimeID))
        return model.availableRuntimes.filter {
            !inPool.contains($0.runtime.id) && $0.runtime.id != RuntimeCatalog.gemini.id
                && model.accounts[$0.runtime.id]?.state != .needsSignIn
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Carry chats on with the next runtime when one runs out",
                       isOn: Binding(get: { pool.isOn }, set: { on in save { $0.isOn = on } }))
            } footer: {
                Text("Offers to carry on at pay-as-you-go prices are always turned down. Needs two runtimes or more.")
            }
            .paperListRow()

            Section {
                List {
                    ForEach(pool.entries) { entry in
                        HStack(spacing: 10) {
                            Text(PoolWords.runtimeName(entry.runtimeID)).fontWeight(.semibold)
                            PaymentCapsule(payment: entry.payment)
                            if let row = model.poolStatus?.rows.first(where: { $0.entry.id == entry.id }), let why = row.unusable {
                                Text("\(why), so skipped").appText(.fine).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Model: \(entry.fallbackModel?.stringValue ?? "as the chat had")")
                                .appText(.fine).foregroundStyle(.secondary)
                            Button("Remove") { save { $0.entries.removeAll { $0.id == entry.id } } }
                                .buttonStyle(.link)
                        }
                    }
                    .onMove { from, to in save { $0.entries.move(fromOffsets: from, toOffset: to) } }
                }
                .frame(minHeight: CGFloat(max(pool.entries.count, 1)) * 34)
                HStack {
                    Menu("Add a runtime") {
                        ForEach(addable) { status in
                            Button(status.runtime.name) {
                                save { $0.entries.append(PoolEntry(runtimeID: status.runtime.id, payment: .allowance(label: nil))) }
                            }
                        }
                    }
                    .disabled(addable.isEmpty)
                    .fixedSize()
                    Button("Add credit on an API key…") { isAddingCredit = true }
                    Text("Free or prepaid credit only. Never suggested.").appText(.fine).foregroundStyle(.secondary)
                }
                if let refusal {
                    Text(refusal).appText(.fine).foregroundStyle(StateTint.failure.style(or: .primary))
                }
            } header: {
                Text("The pool, in the order to try")
            } footer: {
                Text("Drag to reorder. Which model stands in for which is kept on the Pool page, under Matching models.")
            }
            .paperListRow()
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isAddingCredit) {
            AddCreditSheet { entry in save { $0.entries.append(entry) } }
        }
        .task { await model.refreshPoolStatus() }
    }

    /// Change the pool and send the whole of it, as `cost/setLimits` does. The daemon
    /// checks it (FR-001a, FR-032) and says why when it will not keep it.
    private func save(_ change: (inout PoolSettings) -> Void) {
        var next = pool
        change(&next)
        Task { refusal = await model.setPool(next) }
    }
}
