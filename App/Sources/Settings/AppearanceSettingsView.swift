import AgentsKitCore
import AppKit
import SwiftUI

/// Light, dark, or whatever the Mac is set to.
///
/// Paper has a dark sheet as well as a light one, and which one a person reads on is
/// theirs to choose rather than the system's to impose: a Mac kept dark for everything
/// else can still want its long reading on light paper, and the other way about.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// What the whole app is drawn in: nil follows the Mac.
    ///
    /// Set on `NSApp` rather than with `preferredColorScheme`, because it has to reach
    /// every window — the Settings window, a sheet, a popover — and because going back
    /// to nil there reliably hands the choice back to the system, which a view-level
    /// scheme does not always do until the window is reopened.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Where the choice is kept, in `WindowDefaults`: a scratch copy trying the dark sheet
    /// must not leave the real app dark.
    static let defaultsKey = "appearance"

    /// `--appearance dark|light|system`, which wins over the stored choice for the life
    /// of the process. For a scratch copy that has to be seen in a given appearance
    /// without anybody's setting being changed to get there.
    static let launchOverride: Appearance? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count
        else { return nil }
        return Appearance(rawValue: arguments[index + 1])
    }()

    /// Draws the app in `choice`, or in the launch override if there is one.
    @MainActor
    static func apply(_ choice: Appearance) {
        NSApp.appearance = (launchOverride ?? choice).nsAppearance
    }
}

/// Settings ▸ Account (#846): what agents call you.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            PersonSettingsSection()
            // How this person signs in on their other clients is Control plane ▸ Sign-ins (#2197).
        }
        .paperForm()
        .task { await model.refreshPerson() }
    }
}

/// Settings ▸ Machines ▸ This Mac (#846): whether this Mac stays awake, whether Agents Host updates
/// itself (#2178), how long archived agents are kept, and its backups (#1810).
struct MacSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            WakeSettingsSection()
            DesktopControlSettingsSection()
            SelfUpdateSection()
            ArchiveSettingsSection()
            if let backups = model.work.backupState {
                BackupsSection(state: backups, configure: model.configureBackups, make: model.makeBackup,
                               restore: model.restoreBackup, chooseFolder: { chooseBackupFolder(backups) })
            }
        }
        .paperForm()
        .task {
            await model.refreshWakeSettings()
            await model.refreshDesktopControlSettings()
            await model.refreshSelfUpdate()
            await model.refreshRetentionState()
            await model.refreshBackupState()
        }
    }

    /// A second disk or a synced folder, so a backup outlives this Mac's.
    private func chooseBackupFolder(_ state: DaemonAPI.BackupState) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.directoryURL = URL(filePath: state.folder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var settings = state.settings
        settings.folder = url.path(percentEncoded: false)
        Task { try? await model.configureBackups(settings) }
    }
}

/// Settings ▸ Appearance: the theme, kept on this Mac only. Voice mode has its own pane. Show
/// Thoughts (#1725) is in the View menu, next to the chat (#2383).
/// The Dock icon always shows the agents' mood (#2156).
struct AppearanceSettingsView: View {
    @AppStorage(Appearance.defaultsKey, store: WindowDefaults.store) private var appearance = Appearance.system

    var body: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text("System follows your Mac, and changes with it.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
