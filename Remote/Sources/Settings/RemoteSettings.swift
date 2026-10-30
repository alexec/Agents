import AgentsKitCore
import SwiftUI

/// Settings (#846): this app alone (Voice; Live Activities, which only a phone or an iPad has
/// (#1657); and Sidebar, kept on the Mac's host and the same on every client: #1033, #2079),
/// Agent Runtimes ▸ Auto (Core: #2923), and Help. Control plane, machine, user and agent
/// configuration settings are Mac + web (#2796, #2798): the Remote does not have them.
struct RemoteSettings: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(SettingsScope.thisApp.title) {
                    SettingsPageLink("Voice", systemImage: "waveform") { VoiceSettingsSection() }
                    SettingsPageLink("Notifications", systemImage: "bell") {
                        LiveActivitySettingsSection()
                        // Kept on the Mac's host, the same on every client (#2805).
                        NotificationLimitsSection()
                    }
                    // Kept on the Mac's host, the same on every client (#1033, #2079).
                    SettingsPageLink("Sidebar", systemImage: "sidebar.left") { SidebarSettingsSection() }
                }
                .paperListRow()
                // Auto's order and Mappings, kept on the Mac's host (#2658, #2923).
                Section("Agent Runtimes") {
                    AutoSettingsRow()
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
