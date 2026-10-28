import AgentsKitCore
import SwiftUI

/// Settings (#846), in the window's three groups by subject (#2157): This app (Voice; Live
/// Activities, which only a phone or an iPad has (#1657); and Sidebar, kept on the Mac's host and the same on
/// every client: #1033, #2079); Machines (each machine, with what is the same on all of them,
/// and the person's secrets); and Control plane (Sign-ins first, People (#994), Bots (#2132) and the machine providers
/// (#1819)), only once paired (#2260). Each row opens its page. Everything else follows the Mac.
///
/// Each row is a view in a file of its own in this folder, and one line here (#2020), so two
/// features that each add a row touch different lines.
struct RemoteSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section(SettingsScope.thisApp.title) {
                    SettingsPageLink("Voice", systemImage: "waveform") { VoiceSettingsSection() }
                    SettingsPageLink("Notifications", systemImage: "bell") { LiveActivitySettingsSection() }
                    // Kept on the Mac's host, the same on every client (#1033, #2079).
                    SettingsPageLink("Sidebar", systemImage: "sidebar.left") { SidebarSettingsSection() }
                }
                .paperListRow()
                Section(SettingsScope.machines.title) {
                    MachinesSettingsRow()
                    SecretsSettingsRow()
                }
                .paperListRow()
                // Auto's order and Mappings, kept on the Mac's host (#2658).
                Section("Agent Runtimes") {
                    AutoSettingsRow()
                }
                .paperListRow()
                Section("Agent Configuration") {
                    AgentConfigSettingsRow(kind: .skills)
                    AgentConfigSettingsRow(kind: .personas)
                    AgentConfigSettingsRow(kind: .workflows)
                }
                .paperListRow()
                // Not paired yet: no control plane, so no group for it (#2260). The window hides
                // it as well.
                if !model.needsPairing {
                    Section {
                        // In the window's and the page's order (#2267).
                        SignInsSettingsRow()
                        PeopleSettingsRow()
                        BotsSettingsRow()
                        GroupsSettingsRow()
                        ChannelsSettingsRow()
                        SignInProvidersSettingsRow()
                        PolicySettingsRow()
                        MachineProvidersSettingsRow()
                    } header: {
                        Text(SettingsScope.controlPlane.title)
                    } footer: {
                        Text("How you sign in, and the people who use this control plane, with their machines and clients.")
                    }
                    .paperListRow()
                }
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
