import AgentsKitCore
import SwiftUI

/// The Mac's resources, read-only (#116), as sections of This Mac's page (#4027), as the
/// window's and the web page's are of each machine's (#3629): what the person declared, with
/// each one's description and "2 of 3 held", then anything else held or awaited. Only This
/// Mac's: the Remote reads the home Mac's leases alone. Declaring, editing and ending leases
/// stay on the Mac (036 FR-011): a declaration is a short form with numbers in it, made
/// once, and the Mac is where builds and screens are.
struct ResourcesSections: View {
    @Environment(RemoteModel.self) private var model

    /// The id the page scrolls to when a chat's lease line opens it.
    static let top = "resources"

    private var resources: [DaemonAPI.ResourceState] { model.work.leases?.resources ?? [] }
    private var declared: [DaemonAPI.ResourceState] { resources.filter { $0.declared != nil } }
    /// Found and named ones only while someone holds or waits for them.
    private var busy: [DaemonAPI.ResourceState] {
        resources.filter { $0.declared == nil && (!$0.holds.isEmpty || !$0.line.isEmpty) }
    }

    var body: some View {
        Section {
            if declared.isEmpty {
                Text("Nothing declared. Declare resources in Settings \u{25B8} Resources on the Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(declared) { ResourceListRow(state: $0, at: model.work.leases?.at ?? Date()) }
        } header: {
            Text("Resources")
        } footer: {
            Text("Agents lease these whenever the description applies.")
        }
        .id(Self.top)
        if !busy.isEmpty {
            Section("Also held") {
                ForEach(busy) { ResourceListRow(state: $0, at: model.work.leases?.at ?? Date()) }
            }
        }
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
        LeaseWords.agentName(model.work.agent(id)?.title)
    }
}
