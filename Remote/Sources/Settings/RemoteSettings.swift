import AgentsKitCore
import SwiftUI

/// Settings (#846): You first, as on the Mac (#3998): Secrets and For One Session, and Accounts,
/// which are Core (#4032, #4033); this app alone (Voice; Live Activities, which only a phone or an iPad has
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
                // The person's own, on every machine of theirs (#3998), as the Mac's Settings ▸ You.
                Section(SettingsScope.you.title) {
                    NavigationLink {
                        RemoteSecretsPage()
                    } label: {
                        Label(UserScopeWords.secretsTitle, systemImage: "key")
                    }
                    NavigationLink {
                        RemoteAccountsPage()
                    } label: {
                        Label(AccountsWords.title, systemImage: "person.crop.rectangle.stack")
                    }
                }
                .paperListRow()
                Section(SettingsScope.thisApp.title) {
                    SettingsPageLink("Voice", systemImage: "waveform") { VoiceSettingsSection() }
                    // The notice limits are rules of Agents ▸ Policy now (#2957, FR-023).
                    SettingsPageLink("Notifications", systemImage: "bell") { LiveActivitySettingsSection() }
                    // Kept on the Mac's host, the same on every client (#1033, #2079). The archive
                    // switch is a rule of Agents ▸ Policy now (FR-023).
                    SettingsPageLink("Sidebar", systemImage: "sidebar.left") { SidebarSettingsSection() }
                }
                .paperListRow()
                // Agents ▸ Policy is Core (#2957, FR-027): every rule and where it comes from,
                // changed here as on the Mac (#3344).
                Section(PolicyLayersWords.groupTitle) {
                    NavigationLink {
                        PolicyPane(host: model.policyHost, revision: model.policyRevision)
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

/// Settings ▸ You ▸ Secrets (#4032): the person's secrets through the control plane, then the
/// Mac's secrets for one session through its host, as the window's `SecretsView`.
private struct RemoteSecretsPage: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        // Read when the page opens: the control plane's client is not observed.
        SecretsPane(control: model.controlPlane, state: model.userScope,
                    machineNames: SecretInfoWords.names(model.controlHosts)) { SessionSecretsSection(model: model) }
            .navigationTitle(UserScopeWords.secretsTitle)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings ▸ You ▸ Accounts (#4033): the person's outside accounts through the control plane, as
/// the window's `AccountsView`.
private struct RemoteAccountsPage: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        AccountsPane(control: model.controlPlane, state: model.userScope,
                     machineNames: SecretInfoWords.names(model.controlHosts))
            .navigationTitle(AccountsWords.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Status ▸ Secrets and Status ▸ Accounts (#4161), as the window's: what happened last to each of the
/// person's secrets or outside accounts, read only. A tap opens Settings ▸ You ▸ Secrets or Accounts
/// over it.
struct RemoteStatusSecretsPage: View {
    let kind: StatusSecretsKind
    @Environment(RemoteModel.self) private var model
    @State private var editing = false

    var body: some View {
        StatusSecretsPage(kind: kind, control: model.controlPlane, state: model.userScope) { _ in editing = true }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editing) {
                NavigationStack {
                    Group {
                        if kind == .secrets { RemoteSecretsPage() } else { RemoteAccountsPage() }
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false } }
                    }
                }
            }
    }
}
