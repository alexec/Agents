import AgentsKitCore
import SwiftUI

/// Under a host's offline strip, over its chats and the start sheet, while a volume that
/// host's agents write to is low on space (#196), as the window's `DiskStrip` (#195): how
/// much is free, and the largest worktrees when they could be measured. Said where the
/// host's work is, not on every screen, so it never reads as the phone's own disk (#1329).
/// Gone by itself once it climbs back, and while the host is stale, as nothing from it is
/// current then.
struct HostDiskStrip: View {
    @Environment(RemoteModel.self) private var model
    let host: MachineRef

    var body: some View {
        ForEach(alarms) { alarm in
            row(alarm.line, alarm.level)
        }
    }

    private var alarms: [DiskAlarm] {
        if host == .mac {
            return model.isStale || model.needsPairing ? [] : model.work.disk.alarms
        }
        return model.isStale(on: host) ? [] : model.serverDisks[host]?.alarms ?? []
    }

    private func row(_ line: String, _ level: DiskLevel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().tinted(level == .critical ? .failure : .attention)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(line)
                .appText(.fine)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Paper.wash)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
    }
}
