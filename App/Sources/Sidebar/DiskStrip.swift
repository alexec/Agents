import AgentsKitCore
import SwiftUI

/// Across the top of the window while a volume this Mac's agents write to is low on
/// space (#195), beside the control plane's strip: how much is free, and which worktrees
/// are largest when they could be measured. Gone by itself once it climbs back.
struct DiskStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.work.disk.alarms) { alarm in
            row(alarm.line, alarm.level)
        }
        ForEach(model.serverDisks.keys.sorted { model.hosts.label($0) < model.hosts.label($1) }, id: \.self) { host in
            ForEach(model.serverDisks[host]?.alarms ?? []) { alarm in
                row("\(model.hosts.label(host)): \(alarm.line)", alarm.level)
            }
        }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Paper.wash)
        .accessibilityElement(children: .combine)
    }
}
