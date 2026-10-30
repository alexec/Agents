import AgentsKitCore
import SwiftUI

/// Settings ▸ Notifications (#2805): how many notices agents may send, the person's
/// attention that every agent shares. Kept on the Mac's host with the other display
/// choices, so every client shows the same; the host reads them each time an agent calls
/// `notify`. The Mac's Settings window and the Remote's Settings screen draw the same
/// section; the web page has the same under This app.
struct NotificationLimitsSection: View {
    @AppStorage(DisplayPreference.noticeBurst, store: WindowDefaults.store)
    private var burst = DisplayPreference.noticeBurstDefault
    @AppStorage(DisplayPreference.noticeCooldownMinutes, store: WindowDefaults.store)
    private var cooldown = DisplayPreference.noticeCooldownDefault

    var body: some View {
        Section {
            Stepper(value: $burst, in: DisplayPreference.noticeBurstRange) {
                LabeledContent("Burst", value: "\(burst)")
            }
            Picker("Cool-down", selection: $cooldown) {
                ForEach(cooldownChoices, id: \.self) { minutes in
                    Text(Self.label(minutes)).tag(minutes)
                }
            }
        } header: {
            Text("What agents tell you")
        } footer: {
            Text("What agents tell you with a notification, when nothing is to be answered. "
                 + "Burst is how many can go at once; after that, one comes back each cool-down. "
                 + "A notice that would go in the cool-down is not sent, and the agent is told when the next can go. "
                 + "Questions and approvals are not limited.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }

    /// The presets, and the stored value when the web set one that is none of them (#2896).
    private var cooldownChoices: [Int] {
        let presets = DisplayPreference.noticeCooldownPresets
        return presets.contains(cooldown) ? presets : (presets + [cooldown]).sorted()
    }

    static func label(_ minutes: Int) -> String {
        guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}
