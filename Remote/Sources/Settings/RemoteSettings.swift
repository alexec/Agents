import AgentsKitCore
import SwiftUI

/// Settings (#846), in the window's three groups (#1759): This device (Appearance, with
/// Show thoughts as the window's Appearance pane has it (#1725); and Live Activities, which
/// only a phone or an iPad has (#1657)); You (Machines, what the control plane keeps for you,
/// and Sidebar, kept on the Mac's host and the same on every client: #1033, #2079); and Control plane (People (#994) and
/// the workspace providers (#1819)). Each row opens its page. Everything else follows the Mac.
///
/// Each row is a view in a file of its own in this folder, and one line here (#2020), so two
/// features that each add a row touch different lines.
struct RemoteSettings: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(SettingsScope.thisDevice.title) {
                    SettingsPageLink("Appearance", systemImage: "paintbrush") { ThoughtsSettingsSection() }
                    SettingsPageLink("Notifications", systemImage: "bell") { LiveActivitySettingsSection() }
                }
                .paperListRow()
                Section(SettingsScope.you.title) {
                    MachinesSettingsRow()
                    UserScopeSettingsRow()
                    SignInsSettingsRow()
                    // Kept on the Mac's host, the same on every client (#1033, #2079).
                    SettingsPageLink("Sidebar", systemImage: "sidebar.left") { SidebarSettingsSection() }
                }
                .paperListRow()
                Section {
                    PeopleSettingsRow()
                    ChannelsSettingsRow()
                    SignInProvidersSettingsRow()
                    GroupsSettingsRow()
                    // The control plane's workspace providers (#1819), as the page's Settings has them.
                    NavigationLink { WorkspaceProvidersView() } label: {
                        Label(WorkspaceProviderWords.heading, systemImage: "cloud")
                    }
                } header: {
                    Text(SettingsScope.controlPlane.title)
                } footer: {
                    Text("The people who use this control plane, and their machines and clients.")
                }
                .paperListRow()
                // The docs site (#1327), as the Mac's Help ▸ Agents Help.
                Section {
                    Link(destination: HelpSite.url) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
