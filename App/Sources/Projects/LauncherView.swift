import AgentsKitCore
import SwiftUI

/// The main window as a launcher (#1090), with Settings ▸ Sidebar ▸ Home window on Launcher:
/// a card of what needs the person across every project, the pinned, one card per project,
/// the pages about all the work, and Add Project…. Each project opens in a window of its own
/// (#1089), as Xcode's projects do; the launcher is the one place that shows them all.
struct LauncherView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// A page about all the work, open in the launcher in place of its cards.
    @State private var page: LauncherPage?
    @State private var isChoosingFolder = false

    private var projects: [DaemonAPI.ProjectSummary] {
        SidebarOrder.projects(model.liveProjects, servers: model.hosts.servers)
    }

    var body: some View {
        Group {
            if let page {
                page.view
                    .paperGround()
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                self.page = nil
                            } label: {
                                Label("Projects", systemImage: "chevron.left")
                            }
                            .help("Back to the projects")
                        }
                    }
                    .navigationTitle(page.title)
            } else {
                cards
                    .navigationTitle(AppCheckout.windowTitle(nil))
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            Task { await model.addProject(folder) }
        }
    }

    private var cards: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                NeedsYouCard(projects: projects.map(\.key))
                PinnedCard(projects: projects.map(\.key))
                ForEach(projects, id: \.key) { summary in
                    ProjectCard(summary: summary) {
                        openWindow(id: ProjectWindowScene.id, value: summary.key)
                    }
                }
                ActivityCard(open: { page = $0 })
                LauncherCardFrame {
                    isChoosingFolder = true
                } content: {
                    Label("Add Project…", systemImage: "plus")
                        .appText(.reading)
                        .foregroundStyle(Paper.accent)
                }
                .help("Add a folder on this Mac as a project")
            }
            .padding(20)
        }
        .paperGround()
    }
}

/// A page about all the work, as the launcher opens it (#1090): what the sidebar's Status
/// and Usage rows open in the sidebar of every project.
enum LauncherPage: Hashable {
    case events, resources, runtimes, spending

    var title: String {
        switch self {
        case .events: "Events"
        case .resources: "Resources"
        case .runtimes: "Runtimes"
        case .spending: "Cost"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .events: EventsView()
        case .resources: ResourcesView()
        case .runtimes: RuntimesView()
        case .spending: SpendingView()
        }
    }
}

/// A card's frame: a rounded tile, all of it a button.
private struct LauncherCardFrame<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(14)
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(Paper.sidebar, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// One project (#1090): its name and one grey line. A click opens its window (#1089).
private struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.ProjectSummary
    let open: () -> Void

    var body: some View {
        LauncherCardFrame(action: open) {
            Text(SidebarOrder.label(summary) { model.hosts.label($0) })
                .appText(.reading).fontWeight(.semibold)
                .lineLimit(1)
            Text(summary.exists ? LauncherCard.line(for: summary.key, in: model.work) : "Folder is missing")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(model.hostUnreachable(summary.host) ? .secondary : .primary)
        .help("Open \(summary.name) in its own window")
    }
}

/// ✋ Needs You · N, across every project (#1090): the first card. A session opens in its
/// project's window.
private struct NeedsYouCard: View {
    @Environment(AppModel.self) private var model
    let projects: [ProjectKey]

    var body: some View {
        let agents = LauncherCard.needingYou(in: model.work, projects: projects)
        let count = LauncherCard.needsYouCount(in: model.work, projects: projects)
        VStack(alignment: .leading, spacing: 6) {
            Text("✋ Needs You · \(count)")
                .appText(.reading).fontWeight(.semibold)
            if agents.isEmpty {
                Text(count == 0 ? "Nothing is waiting for you" : "Approvals are waiting in their projects")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            }
            ForEach(agents.prefix(6)) { agent in
                SessionLine(agent: agent)
            }
            if agents.count > 6 {
                Text("and \(agents.count - 6) more")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(14)
        .background(Paper.sidebar, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(count > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.separator)))
    }
}

/// The pinned sessions of every project (#1090, Alex): a card, drawn while there are some.
private struct PinnedCard: View {
    @Environment(AppModel.self) private var model
    let projects: [ProjectKey]

    var body: some View {
        let agents = SidebarSmartRow.pinned.agents(in: model.work, projects: projects)
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pinned")
                    .appText(.reading).fontWeight(.semibold)
                ForEach(agents.prefix(6)) { agent in
                    SessionLine(agent: agent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(14)
            .background(Paper.sidebar, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }
}

/// A session on a card: its title and project. A click opens it in its project's window.
private struct SessionLine: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        Button {
            model.openInProjectWindow(agent.id)
        } label: {
            HStack(spacing: 6) {
                Text(agent.title ?? "Untitled")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(agent.projectFolder.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .appText(.supporting)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in its project's window")
    }
}

/// The pages about all the work (#1090): Events, Resources, Runtimes and Cost, opened in the
/// launcher.
private struct ActivityCard: View {
    let open: (LauncherPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity")
                .appText(.reading).fontWeight(.semibold)
            HStack(spacing: 10) {
                ForEach([LauncherPage.events, .resources, .runtimes, .spending], id: \.self) { page in
                    Button(page.title) { open(page) }
                        .buttonStyle(.link)
                }
            }
            .appText(.supporting)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(14)
        .background(Paper.sidebar, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
