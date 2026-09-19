import AgentsKit
import SwiftUI

/// The project itself, filling the page: everything working on it, and somewhere to say
/// what you want done next.
///
/// Laid out the way a chat is, because it is the same kind of page. The name is in the
/// title bar rather than in the content, and the prompt floats at the foot of the pane
/// with the lists scrolling underneath it — the same bar, the same glass, the same
/// margins.
///
/// What you type goes to the project's lead, which is why there is no button for
/// starting an agent by hand. Picking an agent goes into its conversation, and the back
/// button comes out again.
struct ProjectAgentsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    @AppStorage("showsArchivedAgents") private var showsArchived = false
    /// How many archived agents are shown. Raised ten at a time, in the view, because
    /// this window already holds every one of them.
    @State private var archivedShown = Self.pageSize
    @State private var formHeight: CGFloat = 0
    static let pageSize = 10

    private var folder: URL? { model.selectedProject }
    private var summary: DaemonAPI.ProjectSummary? { model.selectedProjectSummary }

    var body: some View {
        ZStack(alignment: .bottom) {
            list
            if let folder {
                ProjectPrompt(folder: folder)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
            }
        }
        .navigationTitle(summary?.name ?? "Project")
        .navigationSubtitle(subtitle)
        .onChange(of: folder) { archivedShown = Self.pageSize }
    }

    /// Where it is, said the way the chat says which folder an agent is in.
    private var subtitle: String {
        guard let summary else { return "" }
        guard summary.exists else { return "Folder is missing" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = summary.folder.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
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
        .listStyle(.inset)
        .animation(.default, value: model.agents.map(\.state))
        // So the last row can be scrolled clear of the prompt floating over it.
        .safeAreaPadding(.bottom, formHeight)
    }

    private var archived: [Agent] {
        model.workers(in: folder, group: .archived)
    }

    /// Out of the way until it is wanted. A link rather than a permanent heading,
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

/// Say what you want done. It goes to the project's lead.
///
/// The same shape as the prompt bar in a chat: one field, one send button, glass, and
/// the same margins, so moving between a project and an agent does not move the thing
/// you type into.
private struct ProjectPrompt: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("What do you want done?", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit(send)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send this to the project lead")
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 144)
        .padding(.vertical, 20)
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
