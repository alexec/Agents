import AgentsKit
import SwiftUI

/// The project itself, with no session picked: its name and somewhere to say what you
/// want done. Nothing else. Its sessions and workflows are
/// the middle column's (`SessionsColumn`); its worktrees, skills and plugins are
/// Configuration's. A plugin waiting for an OK is one line here, since no agent is given
/// it until somebody looks.
///
/// The prompt is the chat's own `PromptBar`, not a copy of it — the runtime picker, the
/// options, the folders and servers, attachments, dictation, the lot. On a project page
/// it is in the same mode it is in for a new chat, with the folder already set to this
/// project, so saying what you want done starts an agent here and takes you into it.
///
/// Everything sits in the same column the transcript and prompt bar use, so the page
/// and a conversation are the same width at every size of window.
struct ProjectAgentsView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?
    @State private var showingConfiguration = false

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
            } else if showingConfiguration {
                ProjectConfigurationView(folder: folder) { showingConfiguration = false }
            } else {
                page
            }
        }
        .onChange(of: model.selectedProjectKey) { showingConfiguration = false }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                // Its own margins, the same as in a chat, so it is not padded twice.
                // The folder is this project's and not the bar's to change.
                PromptBar(folderIsFixed: true)
                    .padding(.top, 4)
                waitingPlugins
                    .chatColumn()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(summary?.name ?? "Project")
        .toolbar {
            ToolbarItem {
                Button { showingConfiguration = true } label: {
                    Label("Project configuration", systemImage: "gearshape")
                }
                .help("Configure this project")
            }
        }
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

    /// Just the name.
    ///
    /// The path used to sit under it. The prompt below carries the folder already, and
    /// saying where the project is twice on one screen is saying it once too often.
    /// What is left here is the one case where the folder is news: it has gone.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary?.name ?? "Project")
                .appText(.title).fontWeight(.semibold)
                .lineLimit(1)
            // Which machine, when it is not this one (037).
            if let summary, summary.host != .mac {
                Text("on \(model.hosts.label(summary.host))")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            if let summary, !summary.exists {
                Label("Folder is missing", systemImage: "exclamationmark.triangle")
                    .appText(.supporting)
                    .tinted(.failure)
                    .lineLimit(1)
                    .help(summary.folder.path)
            }
            if let summary, let spent = spent(summary) {
                Text(spent)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(spentInWords)
                    .accessibilityLabel(spentInWords)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatColumn()
        .padding(.top, 28)
    }

    /// What this project has cost, or nothing at all.
    ///
    /// `Cost.total(of:)` returns nil when nothing has been spent, and nothing is what
    /// is drawn then — a zero would be a claim, and the app has not made one. The
    /// period is named because the sidebar's money line is about this sitting and this
    /// one is about the whole life of the work; a bare figure could be mistaken for it.
    private func spent(_ summary: DaemonAPI.ProjectSummary) -> String? {
        guard let total = Cost.total(of: summary.costToDate) else { return nil }
        guard summary.unmeasuredAgents > 0 else { return "\(total) all time" }
        let chats = summary.unmeasuredAgents == 1 ? "1 chat" : "\(summary.unmeasuredAgents) chats"
        return "\(total) all time · at least, \(chats) went unpriced"
    }

    /// Said in words, because a caption under a name is not something VoiceOver
    /// announces as being about money at all.
    private var spentInWords: String {
        guard let summary, summary.unmeasuredAgents > 0 else {
            return "What this project has cost in total, across every chat in it including archived ones."
        }
        let chats = summary.unmeasuredAgents == 1 ? "chat" : "chats"
        return """
            What this project has cost in total, across every chat in it including \
            archived ones. It is a floor rather than the whole: \
            \(summary.unmeasuredAgents) \(chats) ran on a runtime that reported no price.
            """
    }

    /// Plugins new or changed since they were approved, which no agent is given until
    /// somebody says so on Configuration.
    @ViewBuilder
    private var waitingPlugins: some View {
        let waiting = model.plugins(in: folder).filter { $0.awaitingApproval != nil }
        if !waiting.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised")
                    .tinted(.attention)
                    .accessibilityHidden(true)
                Text(waiting.count == 1
                     ? "Plugin \(waiting[0].name) is waiting for your OK"
                     : "\(waiting.count) plugins are waiting for your OK")
                    .appText(.supporting)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Review") { showingConfiguration = true }
                    .buttonStyle(.paper)
                    .appText(.fine)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRow()
            .padding(.top, 18)
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
