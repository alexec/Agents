import AgentsKitCore
import SwiftUI

/// The project itself, with no session picked: an empty new chat (066, look/ frame A).
///
/// It is laid out as a chat is, with the prompt at the foot of the pane, so starting a
/// session and carrying one on happen in the same place, and sending turns this pane
/// into the session without the bar moving. Above the prompt, the project's name and
/// where it is, where a chat's transcript would be. The project's sessions and workflows
/// are under it in the sidebar (#145), and the button to its settings, a sheet
/// (`ProjectSettingsSheet`), is in the detail's toolbar. Anything in it waiting for somebody's OK — a plugin, a
/// workflow — is one banner across the top, since no agent gets it until somebody looks.
///
/// The prompt is the chat's own `PromptBar`, not a copy of it — the runtime picker, the
/// options, the folders and servers, attachments, dictation, the lot — in the mode it is
/// in for a new chat, with the folder already set to this project.
struct ProjectAgentsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?

    private var folder: URL? { model.selectedProject }
    private var summary: DaemonAPI.ProjectSummary? { model.selectedProjectSummary }

    var body: some View {
        Group {
            if summary == nil {
                // No project: one that was selected has gone (a rebuilt server, 043) or there
                // are none yet. A page with a prompt here would start an agent nowhere.
                EmptyState.noProject
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("")
            } else {
                page
            }
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            WaitingForOKBanner(folder: folder)
            // The same strip as over a chat: a prompt here goes to that host too (#83).
            if let summary { OfflineStrip(host: summary.host) }
            // A change to the project's own files that no session can be asked about (#531).
            if let summary {
                ForEach(model.work.guardedChanges(ofProject: summary.key)) { change in
                    GuardedChangeQuestion(change: change, key: summary.key)
                        .frame(maxWidth: 720)
                        .padding([.horizontal, .top], 16)
                }
            }
            Spacer(minLength: 24)
            heading
            Spacer(minLength: 24)
            // Its own margins, the same as in a chat. The folder is this project's and
            // not the bar's to change.
            PromptBar(folderIsFixed: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(summary?.name ?? "Project")
        .onAppear { adopt(folder) }
        .onChange(of: folder) { _, folder in
            adopt(folder)
        }
        .task(id: folder) {
            if let folder { await model.refreshPlugins(in: folder) }
        }
    }

    /// Point the prompt at this project, so what you type starts an agent here.
    private func adopt(_ folder: URL?) {
        guard let folder, model.draftCwd != folder else { return }
        model.draftCwd = folder
        Task { await model.loadDraftOptions() }
    }

    /// The name, and where the project is, in the middle of the empty pane.
    ///
    /// What it has cost is on Project Settings ▸ General: it is a report, and nobody acts
    /// on it from here. The one thing about the folder that is news here is that it has gone.
    private var heading: some View {
        VStack(spacing: 6) {
            projectMenu
            if let summary {
                Text(place(summary))
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(summary.folder.path)
                if !summary.exists {
                    Label("Folder is missing", systemImage: "exclamationmark.triangle")
                        .appText(.supporting)
                        .tinted(.failure)
                        .lineLimit(1)
                }
            }
        }
        .multilineTextAlignment(.center)
        .chatColumn()
    }

    /// The project's name, as a menu of every project (#495): New Session at the top of
    /// the sidebar starts in the last one used, and this is where another is chosen.
    private var projectMenu: some View {
        Menu {
            ForEach(SidebarOrder.projects(model.liveProjects, servers: model.hosts.servers), id: \.key) { project in
                Button {
                    model.showProject(project.key)
                } label: {
                    if project.key == model.selectedProjectKey {
                        Label(label(project), systemImage: "checkmark")
                    } else {
                        Text(label(project))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(summary?.name ?? "Project")
                    .appText(.title).fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start the session in another project")
        .accessibilityLabel("Project: \(summary?.name ?? "none")")
    }

    private func label(_ project: DaemonAPI.ProjectSummary) -> String {
        SidebarOrder.label(project) { model.hosts.label($0) }
    }

    /// `~/Agents · this Mac`, or the path and the server's name.
    private func place(_ summary: DaemonAPI.ProjectSummary) -> String {
        let machine = summary.host == .mac ? "this Mac" : model.hosts.label(summary.host)
        return "\(ProjectPlace.path(summary.folder, on: summary.host)) · \(machine)"
    }
}

/// Everything in the project waiting for somebody's OK, as one banner across the top of
/// the pane: plugins new or changed since they were approved, which no agent is given
/// until then, and workflows likewise, which do not run. Review opens the one thing when
/// there is one, and otherwise the place they are listed.
struct WaitingForOKBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    let folder: URL?

    private var plugins: [ProjectPlugin] {
        model.plugins(in: folder).filter { $0.awaitingApproval != nil }
    }
    private var workflows: [WorkflowSummary] {
        model.workflows(in: folder).filter { $0.awaitingApproval != nil && !$0.isArchived }
    }

    var body: some View {
        if !plugins.isEmpty || !workflows.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised")
                    .tinted(.attention)
                    .accessibilityHidden(true)
                Text(sentence)
                    .appText(.supporting)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Review…") { review() }
                    .buttonStyle(.paper)
                    .appText(.fine)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.wash)
            .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
            .accessibilityElement(children: .contain)
        }
    }

    private var sentence: String {
        switch (plugins.count, workflows.count) {
        case (1, 0): return "Plugin \(plugins[0].name) is waiting for your OK"
        case (0, 1): return "Workflow \(workflows[0].workflow.name) is waiting for your OK"
        default:
            var parts: [String] = []
            if !plugins.isEmpty { parts.append(plugins.count == 1 ? "1 plugin" : "\(plugins.count) plugins") }
            if !workflows.isEmpty { parts.append(workflows.count == 1 ? "1 workflow" : "\(workflows.count) workflows") }
            let total = plugins.count + workflows.count
            return "\(parts.joined(separator: " and ")) \(total == 1 ? "is" : "are") waiting for your OK"
        }
    }

    /// Plugins first: they are approved on Project Settings, and a workflow is approved
    /// on its own page, which is one click from the middle column anyway.
    private func review() {
        if !plugins.isEmpty {
            requests.projectSettings = .plugins
        } else if let first = workflows.first {
            model.openWorkflow = first.id
        }
    }
}

/// A part of a page, a step above the `GroupHeading`s inside it.
struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .appText(.reading).fontWeight(.semibold)
            .padding(.top, 22)
            .padding(.bottom, 2)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What the cards under it have in common, and how many there are.
struct GroupHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .appText(.fine).fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.top, 14)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}
