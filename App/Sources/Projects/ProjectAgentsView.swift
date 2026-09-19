import AgentsKit
import SwiftUI

/// The agents in the selected project, sorted by whether they want you.
///
/// Three groups, in one order, always: what needs you, what is working, what is done.
/// A group with nothing in it is not drawn at all — an empty heading is furniture, not
/// information. The lead sits above all three, because it is not doing a piece of the
/// work, it is running it.
struct ProjectAgentsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?
    @Binding var isStarting: Bool

    @AppStorage("showsArchivedAgents") private var showsArchived = false
    /// How many archived agents are shown. Raised ten at a time, in the view, because
    /// this window already holds every one of them.
    @State private var archivedShown = Self.pageSize
    static let pageSize = 10

    private var folder: URL? { model.selectedProject }

    var body: some View {
        List(selection: $selection) {
            if let lead = model.lead(of: folder) {
                Section {
                    LeadRow(agent: lead).tag(lead.id)
                }
            }

            ForEach(AgentGroup.live, id: \.self) { group in
                let agents = model.workers(in: folder, group: group)
                if !agents.isEmpty {
                    Section(group.title) {
                        ForEach(agents) { agent in
                            AgentRow(agent: agent).tag(agent.id)
                        }
                    }
                }
            }

            if !archived.isEmpty || showsArchived {
                archivedSection
            }

            if folder != nil, isEmptyOfWorkers {
                EmptyProjectPanel(isStarting: $isStarting, hasLead: model.lead(of: folder) != nil)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(model.selectedProjectSummary?.name ?? "Agents")
        .animation(.default, value: model.agents.map(\.state))
        .onChange(of: folder) { archivedShown = Self.pageSize }
    }

    private var archived: [Agent] {
        model.workers(in: folder, group: .archived)
    }

    private var isEmptyOfWorkers: Bool {
        AgentGroup.live.allSatisfy { model.workers(in: folder, group: $0).isEmpty }
    }

    @ViewBuilder
    private var archivedSection: some View {
        Section(isExpanded: $showsArchived) {
            if archived.isEmpty {
                Text("Nothing archived in this project yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(archived.prefix(archivedShown)) { agent in
                    AgentRow(agent: agent).tag(agent.id)
                }
                if archived.count > archivedShown {
                    Button("Show more") {
                        archivedShown += Self.pageSize
                    }
                    .buttonStyle(.link)
                }
            }
        } header: {
            Text(archived.isEmpty ? "Archived" : "Archived (\(archived.count))")
        }
    }
}

/// A project with a lead and no work in it yet. It says what to do, which is now to
/// tell the lead rather than to start something yourself.
private struct EmptyProjectPanel: View {
    @Binding var isStarting: Bool
    let hasLead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing running here")
                .font(.headline)
            if hasLead {
                Text("Tell the project lead what you want done, and it will start the agents to do it.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Start an agent and say what you want done.")
                    .foregroundStyle(.secondary)
                Button("Start an agent") { isStarting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 8)
    }
}
