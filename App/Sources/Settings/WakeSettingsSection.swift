import AgentsKit
import SwiftUI

/// Settings ▸ General ▸ Sleep. The switch and the hours after the last agent stops.
///
/// What the daemon holds, not what was last clicked. Nil until it has answered, so a
/// daemon too old to know the method draws Appearance and nothing under it.
struct WakeSettingsSection: View {
    @Environment(AppModel.self) private var model

    private var settings: WakeSettings? { model.wakeSettings }

    var body: some View {
        if let settings {
            Section {
                Toggle("Keep this Mac awake while agents are working", isOn: Binding(
                    get: { model.wakeSettings?.keepsAwake ?? false },
                    set: { on in save { $0.keepsAwake = on } }))
                Picker("After they stop", selection: Binding(
                    get: { model.wakeSettings?.graceHours ?? settings.graceHours },
                    set: { hours in save { $0.graceHours = hours } })) {
                    ForEach(WakeSettings.hours, id: \.self) { hours in
                        Text(Self.label(hours)).tag(hours)
                    }
                }
                .disabled(!(model.wakeSettings?.keepsAwake ?? false))
            } header: {
                Text("Sleep")
            } footer: {
                Text((model.wakeSettings?.keepsAwake ?? false)
                     ? "The screen can still sleep. At 20% battery or below, the Mac is allowed to sleep anyway. Once the last agent stops, the Mac stays awake for this long so you can reply."
                     : "The Mac sleeps on its own schedule, including while an agent is working. The time above is kept for when you turn this back on.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
        }
    }

    private static func label(_ hours: Int) -> String {
        switch hours {
        case 0: "Right away"
        case 1: "1 hour"
        default: "\(hours) hours"
        }
    }

    private func save(_ change: (inout WakeSettings) -> Void) {
        guard var next = settings else { return }
        change(&next)
        Task { await model.setWakeSettings(next) }
    }
}
