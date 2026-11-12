import AgentsKitCore
import SwiftUI

/// A move to another machine on its session's row (#4641), on the Mac and the Remote, in the
/// report's place: how far it is, or why it stopped, with × to put that away.
struct MovingLine: View {
    let move: DaemonAPI.MoveNotification
    let isCompact: Bool
    let putAway: () -> Void

    var body: some View {
        if let problem = move.problem {
            HStack(alignment: .top, spacing: 4) {
                Text(problem)
                    .appText(isCompact ? .fine : .supporting)
                    .tinted(.failure)
                    .lineLimit(isCompact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(problem)
                Spacer(minLength: 2)
                Button(action: putAway) { Image(icon: "xmark") }
                    .buttonStyle(.plain)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .help(MoveToMachineWords.putAway)
                    .accessibilityLabel(MoveToMachineWords.putAway)
            }
        } else {
            let line = MoveToMachineWords.moving(to: move.machineName, sent: move.sent, total: move.total,
                                                 branchSent: move.branchSent)
            Text(line)
                .appText(isCompact ? .fine : .supporting)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("\(line) Into \(move.folder) there.")
        }
    }
}
