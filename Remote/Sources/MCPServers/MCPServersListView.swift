import AgentsKitCore
import SwiftUI

/// The MCP servers the Mac runs once for every agent (#488), a page of its own under
/// Activity (#589), as the window's: what each is doing, and why it last stopped.
/// Read-only, as Resources is: a server is hosted from its `mcp.json` on the Mac.
struct MCPServersListView: View {
    @Environment(RemoteModel.self) private var model

    private var servers: [DaemonAPI.HostedMCPStatus] { model.work.hostedMCP?.servers ?? [] }

    var body: some View {
        List {
            Section {
                if servers.isEmpty {
                    Text("No hosted servers. Every MCP server runs in each session that uses it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(servers) { HostedMCPListRow(status: $0) }
                    .paperListRow()
            } footer: {
                Text("Run once on the Mac and shared with every agent, from \"hosted\": true on a stdio entry in mcp.json.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle("MCP Servers")
        // The hosted servers are read with the leases.
        .shows([.leases])
    }
}

/// A server the Mac hosts for every agent (#488): what it is doing, and why it last stopped.
private struct HostedMCPListRow: View {
    let status: DaemonAPI.HostedMCPStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.name).fontWeight(.semibold)
                Spacer()
                Text(HostedMCPWords.place(status)).appText(.fine).foregroundStyle(.secondary)
            }
            Text(HostedMCPWords.line(status)).appText(.fine).foregroundStyle(.secondary)
            if let error = HostedMCPWords.lastError(status) {
                Text(error).appText(.fine)
                    .foregroundStyle(status.state == .restarting
                                     ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The way in, under Activity: how many run, and a red dot when one stopped while in use.
struct MCPServersRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        // The title alone (#587): how many run is said to VoiceOver, and one stopped turns
        // the row's icon red (`activityIcon(_:warns:)`).
        HStack(alignment: .firstTextBaseline) {
            Text("MCP Servers")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(HostedMCPWords.tally(model.work.hostedMCP?.servers ?? [])?.words ?? "")
        .accessibilityHint("Opens MCP Servers")
    }
}
