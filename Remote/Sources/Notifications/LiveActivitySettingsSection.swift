import SwiftUI

/// Settings ▸ Notifications ▸ Live Activities (#1657): a turn sent from here on the Lock
/// Screen and in the Dynamic Island, or not. Off ends every one showing, at once.
struct LiveActivitySettingsSection: View {
    @Environment(RemoteModel.self) private var model
    @AppStorage(TurnActivities.onKey, store: WindowDefaults.store) private var isOn = TurnActivities.onAtFirst

    var body: some View {
        Section {
            Toggle("Live Activities", isOn: $isOn)
                .onChange(of: isOn) { _, on in
                    if !on { model.liveActivities.endAll() }
                }
        } header: {
            Text("Notifications")
        } footer: {
            Text("On, a prompt you send from here shows on the Lock Screen and in the Dynamic Island until its turn ends.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
