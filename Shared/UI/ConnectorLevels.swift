import AgentsKitCore
import SwiftUI

/// The five levels a connector reaches (#1428), as small chips in a row: Tools · Events ·
/// Views · Workflows · Tested. A level reached is in the accent; one not reached is faint.
/// On the catalogue's rows (the window's) and on every Connectors page (the window's and the
/// Remote's). The web page draws the same (`ConnectorLevels` in `W/views/MCPServers.tsx`).
struct ConnectorLevels: View {
    let levels: DaemonAPI.MCPLevels?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MCPHealthWords.levels(levels), id: \.name) { level in
                Text(level.name)
                    .appText(.fine)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(level.reached ? AnyShapeStyle(Paper.accent) : AnyShapeStyle(.tertiary))
                    .background(level.reached ? Paper.accent.opacity(0.14) : Color.secondary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MCPHealthWords.levelsSentence(levels))
        .help(MCPHealthWords.levelsSentence(levels))
    }
}
