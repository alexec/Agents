import AgentsKitCore
import SwiftUI

/// Settings ▸ Agent Configuration ▸ Workflows on the Remote (#3351): the daily summary's one
/// control, kept on the Mac's host, the same on every client.
struct DailySummarySettingsSection: View {
    @Environment(RemoteModel.self) private var model
    @State private var problem: String?

    var body: some View {
        Section {
            if let settings = model.dailySummarySettings {
                DailySummaryControls(settings: settings) { changed in
                    Task { problem = await model.setDailySummarySettings(changed) }
                }
            } else {
                Text("The Mac's host does not say. It may be too old for the daily summary.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Daily summary")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let problem {
                    Text(problem).tinted(.failure)
                }
                Text(DailySummaryControls.footer(for: model.dailySummarySettings?.mode ?? .off))
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
        }
        .paperListRow()
        .task { await model.refreshDailySummarySettings() }
    }
}
