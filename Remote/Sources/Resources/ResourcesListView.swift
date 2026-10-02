import AgentsKitCore
import SwiftUI

/// The Mac's resources, read-only (#116): what the person declared, with each one's
/// description and "2 of 3 held", then anything held or awaited. Declaring, editing
/// and ending leases stay on the Mac (036 FR-011): a declaration is a short form with
/// numbers in it, made once, and the Mac is where builds and screens are.
struct ResourcesListView: View {
    @Environment(RemoteModel.self) private var model

    private var resources: [DaemonAPI.ResourceState] { model.work.leases?.resources ?? [] }
    private var declared: [DaemonAPI.ResourceState] { resources.filter { $0.declared != nil } }
    /// Found and named ones only while someone holds or waits for them.
    private var busy: [DaemonAPI.ResourceState] {
        resources.filter { $0.declared == nil && (!$0.holds.isEmpty || !$0.line.isEmpty) }
    }

    var body: some View {
        List {
            Section {
                if declared.isEmpty {
                    Text("Nothing declared. Declare resources in Settings \u{25B8} Resources on the Mac.")
                        .foregroundStyle(.secondary)
                }
                ForEach(declared) { ResourceListRow(state: $0, at: model.work.leases?.at ?? Date()) }
                    .paperListRow()
            } header: {
                Text("Declared")
            } footer: {
                Text("Agents lease these whenever the description applies.")
            }
            Section("Held now") {
                if busy.isEmpty { Text("Nothing else is held.").foregroundStyle(.secondary) }
                ForEach(busy) { ResourceListRow(state: $0, at: model.work.leases?.at ?? Date()) }
                    .paperListRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle("Resources")
    }
}

private struct ResourceListRow: View {
    @Environment(RemoteModel.self) private var model
    let state: DaemonAPI.ResourceState
    let at: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.displayName).fontWeight(.semibold)
                Spacer()
                Text(state.heldCount ?? (state.holds.isEmpty ? "Free" : "Held"))
                    .appText(.fine).monospacedDigit().foregroundStyle(.secondary)
            }
            if let declared = state.declared {
                Text(declared.description).appText(.fine).foregroundStyle(.secondary)
            }
            ForEach(state.holds, id: \.holder) { lease in
                Text("\(name(lease.holder)) until \(LeaseWords.clock(lease.expiresAt)) \u{00B7} "
                     + "\(LeaseWords.minutesLeft(until: lease.expiresAt, now: at)) min left")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            if !state.line.isEmpty {
                Text("\(state.line.count) waiting: " + state.line.map { name($0.agentID) }.joined(separator: ", "))
                    .appText(.fine).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func name(_ id: UUID) -> String {
        LeaseWords.agentName(model.work.agents.first { $0.id == id }?.title)
    }
}

/// The way in, under Activity, with how much is held on the way past.
struct ResourcesRow: View {
    @Environment(RemoteModel.self) private var model

    private var counts: String? {
        guard let resources = model.work.leases?.resources else { return nil }
        let held = resources.reduce(0) { $0 + $1.holds.count }
        let waiting = resources.reduce(0) { $0 + $1.line.count }
        guard held + waiting > 0 else { return nil }
        return "\(held) held \u{00B7} \(waiting) waiting"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Resources", systemImage: "lock")
            Spacer()
            if let counts {
                Text(counts).monospacedDigit().appText(.fine).foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Opens Resources")
    }
}
