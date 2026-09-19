import AgentsKit
import SwiftUI

/// The project itself: its name, somewhere to say what you want done, and everything
/// working on it.
///
/// The prompt is at the top because it is how work starts here. You describe the
/// outcome, the project's lead takes it, and the agents it starts appear in the lists
/// below. That is why there is no button for starting one by hand any more.
struct ProjectAgentsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    @AppStorage("showsArchivedAgents") private var showsArchived = false
    /// How many archived agents are shown. Raised ten at a time, in the view, because
    /// this window already holds every one of them.
    @State private var archivedShown = Self.pageSize
    static let pageSize = 10

    private var folder: URL? { model.selectedProject }

    var body: some View {
        VStack(spacing: 0) {
            if let summary = model.selectedProjectSummary {
                ProjectHeader(summary: summary)
                Divider()
                ProjectPrompt(folder: summary.folder)
                Divider()
            }
            list
        }
        .navigationTitle(model.selectedProjectSummary?.name ?? "Project")
        .onChange(of: folder) { archivedShown = Self.pageSize }
    }

    private var list: some View {
        List(selection: $selection) {
            if let lead = model.lead(of: folder) {
                LeadRow(agent: lead).tag(lead.id)
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

            archivedSection
        }
        .listStyle(.sidebar)
        .animation(.default, value: model.agents.map(\.state))
    }

    private var archived: [Agent] {
        model.workers(in: folder, group: .archived)
    }

    /// Out of the way until it is wanted. A button rather than a permanent heading,
    /// because looking at what you archived is a rare thing to want.
    @ViewBuilder
    private var archivedSection: some View {
        if showsArchived {
            Section("Archived") {
                if archived.isEmpty {
                    Text("Nothing archived in this project yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(archived.prefix(archivedShown)) { agent in
                        AgentRow(agent: agent).tag(agent.id)
                    }
                    if archived.count > archivedShown {
                        Button("Show more") { archivedShown += Self.pageSize }
                            .buttonStyle(.link)
                    }
                }
                Button("Hide archived") { showsArchived = false }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
            }
        } else if folder != nil {
            Button("Show archived") { showsArchived = true }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
        }
    }
}

/// What this project is, at the top of it.
private struct ProjectHeader: View {
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.name)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(abbreviatedPath)
                .font(.caption)
                .foregroundStyle(summary.exists ? Color.secondary : Color.red)
                .lineLimit(1)
                .help(summary.exists ? summary.folder.path : "This folder is not there any more.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var abbreviatedPath: String {
        guard summary.exists else { return "Folder is missing" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = summary.folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Say what you want done. It goes to the project's lead.
private struct ProjectPrompt: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("What do you want done?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .help("Send this to the project lead")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !isEmpty else { return }
        let words = text
        text = ""
        Task { await model.sendToLead(of: folder, words) }
    }
}
