import AgentsKitCore
import SwiftUI

/// One MCP server on an MCP Servers page (#753), the window's and the Remote's: its dot,
/// its name and how it runs, how it is doing, why it last failed
/// in the failure tint, and the five levels it reaches (#1428).
/// The words are `MCPHealthWords`, as the web page has them.
struct MCPHealthRow: View {
    let server: DaemonAPI.MCPServerHealth

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MCPHealthDot(tone: MCPHealthWords.tone(server)).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(server.name).appText(.reading).fontWeight(.semibold)
                    Text(MCPHealthWords.kind(server)).appText(.fine).foregroundStyle(.secondary)
                }
                Text(MCPHealthWords.line(server)).appText(.fine).foregroundStyle(.secondary)
                if let error = MCPHealthWords.lastError(server) {
                    Text(error)
                        .appText(.fine)
                        .foregroundStyle(MCPHealthWords.tone(server) == .failing
                                         ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ConnectorLevels(levels: server.levels).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Filled when it answers or runs, the failure tint when it does not, hollow otherwise.
struct MCPHealthDot: View {
    let tone: MCPHealthWords.Tone

    var body: some View {
        switch tone {
        case .good:
            Circle().fill(.secondary).frame(width: 10, height: 10)
        case .failing:
            Circle().fill(StateTint.failure.style(or: .secondary)).frame(width: 10, height: 10)
        case .quiet:
            Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
        }
    }
}
