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
/// What you type starts an agent on it, in this folder, which is why there is no
/// separate button for starting one. Picking an agent goes into its conversation, and
/// the back button comes out again.
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

    /// Everything working on this project, each one a card.
    ///
    /// A card rather than a row because each one is a way in: tapping it opens that
    /// agent's conversation. One `GlassEffectContainer` around the lot, so the cards
    /// blend with each other rather than each carrying its own separate render.
    private var list: some View {
        ScrollView {
            GlassEffectContainer(spacing: Self.cardSpacing) {
                LazyVStack(alignment: .leading, spacing: Self.cardSpacing) {
                    ForEach(AgentGroup.live, id: \.self) { group in
                        let agents = model.agents(in: folder, group: group)
                        if !agents.isEmpty {
                            GroupHeading(title: group.title, count: agents.count)
                            ForEach(agents) { agent in
                                AgentCard(id: agent.id, selection: $selection) {
                                    AgentRow(agent: agent)
                                }
                            }
                        }
                    }

                    archivedSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .animation(.default, value: model.agents.map(\.state))
        // So the last card can be scrolled clear of the prompt floating over it.
        .safeAreaPadding(.bottom, formHeight)
    }

    static let cardSpacing: CGFloat = 10

    private var archived: [Agent] {
        model.agents(in: folder, group: .archived)
    }

    /// Out of the way until it is wanted, because looking at what you archived is a
    /// rare thing to want.
    @ViewBuilder
    private var archivedSection: some View {
        if showsArchived {
            GroupHeading(title: "Archived", count: archived.count)
            if archived.isEmpty {
                Text("Nothing archived in this project yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(archived.prefix(archivedShown)) { agent in
                    AgentCard(id: agent.id, selection: $selection) {
                        AgentRow(agent: agent)
                    }
                }
                if archived.count > archivedShown {
                    Button("Show more") { archivedShown += Self.pageSize }
                        .buttonStyle(.glass)
                }
            }
            Button("Hide archived") { showsArchived = false }
                .buttonStyle(.glass)
                .padding(.top, 2)
        } else if folder != nil {
            Button("Show archived") { showsArchived = true }
                .buttonStyle(.glass)
                .padding(.top, 6)
        }
    }
}

/// One agent, as a card you can go into.
///
/// It is a real control — the whole card opens that conversation — which is what
/// earns it interactive glass rather than a decorated background.
private struct AgentCard<Content: View>: View {
    let id: UUID
    @Binding var selection: UUID?
    @ViewBuilder var content: Content

    var body: some View {
        Button {
            selection = id
        } label: {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 14))
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// What the cards under it have in common, and how many there are.
private struct GroupHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.top, 10)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Say what you want done. It starts an agent on it.
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
            .help("Start an agent on this")
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
        Task { await model.startAgent(in: folder, prompt: words) }
    }
}
