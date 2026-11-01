import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines ▸ This Mac ▸ Desktop control (#3004, US2): the off-by-default
/// switch for `drive_screen`, an agent driving another app's own screen, mouse and
/// keyboard.
///
/// What the daemon holds, not what was last clicked. Nil until it has answered, so a
/// daemon too old to know the method draws nothing here (WakeSettingsSection's own shape).
struct DesktopControlSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let settings = model.desktopControlSettings {
            Section {
                Toggle("Let an agent drive apps on this Mac", isOn: Binding(
                    get: { settings.enabled },
                    set: { on in Task { await model.setDesktopControlEnabled(on) } }))
            } header: {
                Text("Desktop control")
            } footer: {
                Text(settings.enabled
                     ? "An agent can click, type and read the screen of any app on this Mac, not only the sandboxed browser. macOS will ask you to grant Agents Host the Accessibility permission the first time an agent tries."
                     : "Off by default. An agent cannot click, type or read the screen of any other app until you turn this on.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
        }
    }
}
