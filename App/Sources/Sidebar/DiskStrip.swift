import AgentsKitCore
import SwiftUI

/// Under a host's offline strip, over its chats and its folder's page, while a volume
/// that host's agents write to is low on space (#195): how much is free, and which
/// worktrees are largest when they could be measured. Said where the host's work is,
/// not across the window, so it never reads as the client's own disk (#1329). Gone by
/// itself once it climbs back.
struct DiskStrip: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    var body: some View {
        ForEach(alarms) { alarm in
            row(alarm.line, alarm.level)
        }
    }

    private var alarms: [DiskAlarm] {
        host == .mac ? model.work.disk.alarms : model.serverDisks[host]?.alarms ?? []
    }

    private func row(_ line: String, _ level: DiskLevel) -> some View {
        HStack(spacing: 10) {
            Circle().tinted(level == .critical ? .failure : .attention).frame(width: 7, height: 7)
            Text(line)
                .appText(.supporting)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .chatColumn()
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}
