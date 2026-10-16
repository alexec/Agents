import AgentsKitCore
import SwiftUI

/// The launcher (#1090), the home screen with Settings ▸ Sidebar ▸ Home window on Launcher:
/// cards in place of the sidebar, as the Mac's main window has them. Needs You across every
/// project first, then the pinned, one card per project, the pages about all the work, and
/// Settings. A project opens its own screen (#1089), with ‹ All back to the cards.
struct RemoteLauncher: View {
    @Environment(RemoteModel.self) private var model
    @State private var showsSettings = false

    private var servers: [HostID] { model.hostSections.map(\.id).filter { $0 != .mac } }

    var body: some View {
        let projects = SidebarOrder.projects(model.projects, servers: servers)
        let keys = projects.map(\.key)
        List {
            Section {
                let agents = LauncherCard.needingYou(in: model.work, projects: keys)
                let count = LauncherCard.needsYouCount(in: model.work, projects: keys)
                Text("✋ Needs You · \(count)")
                    .appText(.reading).fontWeight(.semibold)
                if count == 0 {
                    Text("Nothing is waiting for you").appText(.supporting).foregroundStyle(.secondary)
                }
                ForEach(agents) { agent in
                    sessionButton(agent)
                }
            }
            let pinned = SidebarSmartRow.pinned.agents(in: model.work, projects: keys)
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { agent in sessionButton(agent) }
                }
            }
            Section("Projects") {
                ForEach(projects, id: \.key) { summary in
                    Button {
                        model.phoneProject = summary.key
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(SidebarOrder.label(summary) { model.hostLabel($0) })
                                .appText(.reading).fontWeight(.semibold)
                                .foregroundStyle(model.hostIsOffline(summary.host) ? .secondary : .primary)
                            Text(summary.exists ? LauncherCard.line(for: summary.key, in: model.work) : "Folder is missing")
                                .appText(.supporting)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityHint("Opens the project on its own")
                }
            }
            Section("Activity") {
                ForEach([(SidebarItem.events, "Events"), (.resources, "Resources"), (.runtimes, "Runtimes"),
                         (.spending, "Cost")], id: \.1) { item, title in
                    Button(title) { model.sidebarItem = item }
                }
            }
            Section {
                Button("Settings…") { showsSettings = true }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .navigationTitle("Agents")
        .sheet(isPresented: $showsSettings) { RemoteSettings() }
        .shows([.workflows, .pins, .leases])
        .refreshable { await model.catchUp() }
    }

    /// A session on a card: its title and project. A tap opens it in its project's screen.
    private func sessionButton(_ agent: Agent) -> some View {
        Button {
            model.openInProjectScreen(agent.id)
        } label: {
            HStack {
                Text(agent.title ?? "Untitled").lineLimit(1)
                Spacer(minLength: 6)
                Text(agent.projectFolder.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }
            .appText(.supporting)
        }
    }
}
