import AgentsKitCore
import SwiftUI

/// Each runtime on the Mac and where its allowance stands (065, US4): out, since when,
/// when it is next checked, and what is left of its plan. The Mac's Agent Runtimes
/// words, as a list. Mark available is a swipe action, and Assess in… (#47) is in a row's menu.
struct RuntimesView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        List {
            if let allowances = model.runtimeAllowances {
                ForEach(allowances.rows) { row in
                    RuntimeAllowanceRow(row: row, at: allowances.at)
                        // Assess it (#47), in one of the Mac's projects, as Settings does there.
                        .contextMenu {
                            Menu("Assess in…") {
                                ForEach(macProjects) { summary in
                                    Button(summary.name) { assess(row.runtimeID, in: summary.project.folder) }
                                }
                            }
                        }
                        .swipeActions {
                            if row.state.isOut {
                                Button("Mark available") { Task { await model.markRuntimeAvailable(row.credentialKey) } }
                                    .tint(.gray)
                            }
                        }
                }
            }
        }
        .navigationTitle("Runtimes")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .overlay {
            if model.runtimeAllowances?.rows.isEmpty != false {
                Text("No runtimes on the Mac yet.").foregroundStyle(.secondary)
            }
        }
        .task { await model.refreshRuntimeAllowances() }
        .refreshable { await model.refreshRuntimeAllowances() }
        .alert("Not started", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    @State private var refusal: String?

    private var macProjects: [DaemonAPI.ProjectSummary] {
        model.projects.filter { $0.host == .mac && $0.exists }
    }

    private func assess(_ runtimeID: String, in folder: URL) {
        Task { refusal = await model.assessRuntime(runtimeID, in: folder) }
    }
}

private struct RuntimeAllowanceRow: View {
    let row: RuntimeAllowances.Row
    let at: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PoolWords.runtimeName(row.runtimeID)).fontWeight(.semibold)
            Text(row.unusable.map { "Not usable: \($0)" } ?? row.line(now: at))
                .appText(.fine)
                .foregroundStyle(row.state.isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
            if row.unusable == nil, let reading = PoolWords.reading(row.state.reading, now: at) {
                Text(reading).appText(.fine).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The link to it at the foot of Spending, with the Mac's red dot when a runtime is out.
struct RuntimesLink: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationLink { RuntimesView() } label: {
            HStack {
                Label("Runtimes", systemImage: "cpu")
                Spacer()
                if model.runtimeAllowances?.anyOut == true {
                    Circle().fill(StateTint.failure.style(or: .primary)).frame(width: 8, height: 8)
                        .accessibilityLabel("A runtime is out")
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
