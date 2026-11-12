import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines ▸ This Mac ▸ Desktop control (#3004, US2, #4264): Ask, Always
/// Approve or Off for `drive_screen`, an agent driving another app's own screen, mouse and
/// keyboard. Ask is the default: each lease of the screen waits on the person in Needs you.
///
/// What the daemon holds, not what was last clicked. Nil until it has answered, so a
/// daemon too old to know the method draws nothing here (WakeSettingsSection's own shape).
struct DesktopControlSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let settings = model.desktopControlSettings {
            Section {
                Picker(DriveApprovalWords.screenLabel, selection: Binding(
                    get: { settings.shownMode },
                    set: { mode in Task { await model.setDesktopControl(mode) } })) {
                    ForEach(DriveApproval.allCases) { Text($0.word).tag($0) }
                }
            } header: {
                Text("Desktop control")
            } footer: {
                Text(DriveApprovalWords.screenFooter(settings.shownMode))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
        }
    }
}
