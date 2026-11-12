import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines ▸ Browser (#3535): this Mac's browser (#3533), the one Chromium that
/// agents on this Mac drive, with a kept profile. The sites it keeps cookies for, which is
/// how a site remembers a sign-in, Clear for one of them or all, and the size of the
/// download. Asked for each time the pane shows; reading the sites starts Chromium when it
/// is downloaded and not running.
struct BrowserSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: BrowserState?
    @State private var loaded = false
    @State private var clearing: String?
    @State private var asksClearAll = false
    @State private var control: BrowserControlSettings?

    var body: some View {
        Form {
            // Ask, Always Approve or Off (#4264). Not drawn for a daemon too old to know it.
            if let control {
                Section {
                    Picker(DriveApprovalWords.browserLabel, selection: Binding(
                        get: { control.mode },
                        set: { mode in Task { if let saved = await model.setBrowserControl(mode) { self.control = saved } } })) {
                        ForEach(DriveApproval.allCases) { Text($0.word).tag($0) }
                    }
                } header: {
                    Text(DriveApprovalWords.browserHeader)
                } footer: {
                    Text(DriveApprovalWords.browserFooter(control.mode))
                }
                .paperListRow()
            }
            Section {
                if let state, state.installed {
                    if let problem = state.problem {
                        Text(problem).foregroundStyle(.secondary)
                    } else if state.sites.isEmpty {
                        Text(BrowserSettingsWords.noSites).foregroundStyle(.secondary)
                    }
                    ForEach(state.sites) { site in
                        LabeledContent {
                            Button(BrowserSettingsWords.clear) { Task { await clear(site.site) } }
                                .accessibilityLabel(BrowserSettingsWords.clearSite(site.site))
                                .disabled(clearing != nil)
                        } label: {
                            Text(site.site)
                            Text(BrowserSettingsWords.cookies(site.cookies))
                        }
                    }
                    if state.sites.count > 1 {
                        HStack {
                            Spacer()
                            Button(BrowserSettingsWords.clearAll) { asksClearAll = true }
                                .disabled(clearing != nil)
                        }
                    }
                } else if loaded {
                    Text(BrowserSettingsWords.notDownloaded).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                Text(BrowserSettingsWords.sitesHeader)
            } footer: {
                Text(BrowserSettingsWords.sitesFooter)
            }
            .paperListRow()

            Section {
                LabeledContent(BrowserSettingsWords.downloadLabel) {
                    Text(state.map { $0.installed ? BrowserSettingsWords.size($0.downloadBytes) : BrowserSettingsWords.notDownloadedShort } ?? "")
                }
            } header: {
                Text(BrowserSettingsWords.downloadHeader)
            } footer: {
                Text(BrowserSettingsWords.downloadFooter)
            }
            .paperListRow()
        }
        .paperForm()
        .task {
            control = await model.browserControl()
            state = await model.browserState()
            loaded = true
        }
        .confirmationDialog(BrowserSettingsWords.clearAllQuestion, isPresented: $asksClearAll) {
            Button("Clear All", role: .destructive) { Task { await clear(nil) } }
        } message: {
            Text(BrowserSettingsWords.clearAllDetail)
        }
    }

    private func clear(_ site: String?) async {
        clearing = site ?? ""
        defer { clearing = nil }
        if let cleared = await model.clearBrowser(site: site) { state = cleared }
    }
}
