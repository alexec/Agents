import AgentsKit
import SwiftUI

/// The project itself, filling the page: its name, somewhere to say what you want done,
/// and the agents working on it.
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

    @AppStorage("showsArchivedAgents") private var showsArchived = false
    /// How many archived agents are shown. Raised ten at a time, in the view, because
    /// this window already holds every one of them.
    @State private var archivedShown = Self.pageSize
    static let pageSize = 10
    static let cardSpacing: CGFloat = 2

    private var folder: URL? { model.selectedProject }
    private var summary: DaemonAPI.ProjectSummary? { model.selectedProjectSummary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heading
                SectionHeading(title: "New session")
                    .chatColumn()
                    .padding(.top, 6)
                // Its own margins, the same as in a chat, so it is not padded twice.
                // The folder is this project's and not the bar's to change.
                PromptBar(folderIsFixed: true)
                    .padding(.top, -10)
                agents
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(summary?.name ?? "Project")
        .onAppear { adopt(folder) }
        .onChange(of: folder) { _, folder in
            archivedShown = Self.pageSize
            adopt(folder)
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
            if let summary, !summary.exists {
                Label("This folder is not there any more", systemImage: "exclamationmark.triangle")
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

    /// Everything working on this project, each one a card you can go into.
    ///
    /// One `GlassEffectContainer` around the lot, so the cards blend with each other
    /// rather than each carrying its own separate render.
    private var agents: some View {
        GlassEffectContainer(spacing: Self.cardSpacing) {
            LazyVStack(alignment: .leading, spacing: Self.cardSpacing) {
                if folder != nil {
                    SectionHeading(title: "Sessions")
                    if !hasSessions {
                        Text("No sessions")
                            .appText(.reading)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
                ForEach(AgentGroup.live, id: \.self) { group in
                    let agents = model.agents(in: folder, group: group)
                    if !agents.isEmpty {
                        GroupHeading(title: group.title, count: agents.count)
                        ForEach(agents) { agent in
                            AgentCard(id: agent.id, selection: $selection) {
                                AgentRow(agent: agent)
                            }
                            .swipeToArchive { await model.archive(agent.id) }
                        }
                    }
                }

                // The archive closes the chats, before the workflows start.
                archivedSection

                // Under the agents: what will happen, after what is happening. See
                // `WorkflowsSection` for why that order.
                WorkflowsSection(folder: folder, selection: $selection)

                // Worktrees the app made here, which outlive the agents in them (030).
                WorktreesSection(folder: folder)
            }
            .chatColumn()
            .padding(.bottom, 28)
        }
        .animation(.default, value: model.agents.map(\.state))
        // Parking moves a chat without changing its state (040).
        .animation(.default, value: model.agents.map(\.parking))
        // Who is working in which worktree changes when an agent is archived or
        // brought back, so the list is asked for again then. Not polled.
        .onChange(of: archived.count) { Task { await model.loadDraftWorktrees() } }
    }

    private var hasSessions: Bool {
        AgentGroup.allCases.contains { !model.agents(in: folder, group: $0).isEmpty }
    }

    private var archived: [Agent] {
        model.agents(in: folder, group: .archived)
    }

    /// Out of the way until it is wanted, because looking at what you archived is a
    /// rare thing to want. Behind the same chevron heading as archived workflows.
    @ViewBuilder
    private var archivedSection: some View {
        if folder != nil, !archived.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.18)) { showsArchived.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsArchived ? "chevron.down" : "chevron.right")
                        .appText(.fine)
                    Text("Archived")
                    Text("\(archived.count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .appText(.fine).fontWeight(.medium)
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)

            if showsArchived {
                ForEach(archived.prefix(archivedShown)) { agent in
                    AgentCard(id: agent.id, selection: $selection) {
                        AgentRow(agent: agent)
                    }
                }
                if archived.count > archivedShown {
                    Button("Show more") { archivedShown += Self.pageSize }
                        .buttonStyle(.paper)
                }
            }
        }
    }
}

/// One agent, as a card you can go into.
///
/// It is a real control — the whole card opens that conversation — which is why it
/// is a paper row that answers the pointer rather than a line of text.
private struct AgentCard<Content: View>: View {
    let id: UUID
    @Binding var selection: UUID?
    @ViewBuilder var content: Content

    var body: some View {
        Button {
            selection = id
        } label: {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .paperRow()
        }
        .buttonStyle(.plain)
    }
}

/// One of the page's three parts — starting a session, the sessions, the workflows —
/// a step above the `GroupHeading`s inside them.
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
