import AgentsKitCore
import SwiftUI

/// The MCP servers this Mac runs once for every agent (#488), a page of its own under
/// Activity (#589): what each is doing, and why it last stopped. It was a group on
/// Resources, which is about leases.
///
/// Read-only: a server is hosted by `"hosted": true` on a stdio entry in its `mcp.json`.
/// An http server is already one copy for every client, so the key does nothing there.
struct MCPServersView: View {
    @Environment(AppModel.self) private var model

    private var servers: [DaemonAPI.HostedMCPStatus] { model.hostedMCP?.servers ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("MCP servers this Mac runs once and shares with every agent, rather than one "
                     + "copy in each session. A stdio entry in mcp.json is hosted with \"hosted\": true.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                if !servers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, status in
                            if index > 0 { Divider().padding(.leading, 32) }
                            HostedMCPRow(status: status)
                        }
                    }
                    .padding(.vertical, 4)
                    .paperRaised(in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("MCP Servers")
        .overlay {
            if servers.isEmpty {
                Text("No hosted servers. Every MCP server runs in each session that uses it.")
                    .foregroundStyle(.secondary)
            }
        }
        .task { await model.refreshHostedMCP() }
    }
}

/// One hosted server: its state's dot, its name and whose file, its line, and why it last
/// stopped, in the failure tint while it is starting again.
private struct HostedMCPRow: View {
    let status: DaemonAPI.HostedMCPStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            dot.padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(status.name).appText(.reading).fontWeight(.semibold)
                    Text(HostedMCPWords.place(status)).appText(.fine).foregroundStyle(.secondary)
                }
                Text(HostedMCPWords.line(status)).appText(.fine).foregroundStyle(.secondary)
                if let error = HostedMCPWords.lastError(status) {
                    Text(error)
                        .appText(.fine)
                        .foregroundStyle(status.state == .restarting
                                         ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var dot: some View {
        switch status.state {
        case .running, .starting:
            Circle().fill(.secondary).frame(width: 10, height: 10)
        case .restarting:
            Circle().fill(StateTint.failure.style(or: .secondary)).frame(width: 10, height: 10)
        case .idle:
            Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
        }
    }
}

/// The way into MCP Servers under Activity: how many run, and a red dot when one stopped
/// while in use.
struct MCPServersRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MCP Servers").foregroundStyle(.primary)
            Spacer()
            if let tally = HostedMCPWords.tally(model.hostedMCP?.servers ?? []) {
                HStack(spacing: 4) {
                    if tally.stopped {
                        Circle().fill(StateTint.failure.style(or: .primary)).frame(width: 8, height: 8)
                    }
                    Text(tally.words).monospacedDigit()
                }
                .appText(.fine)
                .foregroundStyle(.secondary)
            }
        }
        .help("The MCP servers this Mac runs once for every agent, and why each last stopped")
    }
}
