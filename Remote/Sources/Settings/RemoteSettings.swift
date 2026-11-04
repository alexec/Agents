import AgentsKitCore
import SwiftUI

/// Settings (#846): this app alone (Voice; Live Activities, which only a phone or an iPad has
/// (#1657); and Sidebar, kept on the Mac's host and the same on every client: #1033, #2079), and
/// Help. Control plane, machine, user and agent configuration settings are Mac + web (#2796,
/// #2798): the Remote does not have them, but for Agents ▸ Policy (#2957) and the daily
/// summary's control (#3351), which are Core.
struct RemoteSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section(SettingsScope.thisApp.title) {
                    SettingsPageLink("Voice", systemImage: "waveform") { VoiceSettingsSection() }
                    // The notice limits are rules of Agents ▸ Policy now (#2957, FR-023).
                    SettingsPageLink("Notifications", systemImage: "bell") { LiveActivitySettingsSection() }
                    // Kept on the Mac's host, the same on every client (#1033, #2079). The archive
                    // switch is a rule of Agents ▸ Policy now (FR-023).
                    SettingsPageLink("Sidebar", systemImage: "sidebar.left") { SidebarSettingsSection() }
                }
                .paperListRow()
                // Agents ▸ Policy is Core (#2957, FR-027): every rule and where it comes from, read
                // only but for the notice limits and the archive switch.
                Section(PolicyLayersWords.groupTitle) {
                    NavigationLink {
                        PolicyPane(host: model.policyHost, revision: model.policyRevision,
                                   editableRules: PolicyLayersWords.remoteEditable)
                            .navigationTitle(PolicyLayersWords.title)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label(PolicyLayersWords.title, systemImage: PolicyLayersWords.symbol)
                    }
                }
                .paperListRow()
                // The daily summary is Core (#3351): its one control, as the Mac's and the web's
                // Agent Configuration ▸ Workflows.
                Section("Agent Configuration") {
                    SettingsPageLink("Workflows", systemImage: "clock.arrow.circlepath") { DailySummarySettingsSection() }
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
