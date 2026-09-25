import AgentsKit
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

    /// Where the choice is kept, scoped by root the way drafts are: every copy of the
    /// app shares one defaults domain, and a scratch copy trying the dark sheet must not
    /// leave the real app dark.
    static var defaultsKey: String {
        let locations = StoreLocations.default
        return locations.isStandard ? "appearance" : "appearance.root:\(locations.name)"
    }

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

struct AppearanceSettingsView: View {
    @AppStorage(Appearance.defaultsKey) private var appearance = Appearance.system

    var body: some View {
        Form {
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
        .paperForm()
        .frame(width: 460)
    }
}
