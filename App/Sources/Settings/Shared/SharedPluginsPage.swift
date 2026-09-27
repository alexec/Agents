import AgentsKit
import SwiftUI

/// Frame E: one folder per plugin; the row says what is inside, the detail says how each
/// runtime is handed it, since that differs for every one (research R9, R12). Removing one
/// is Finder's job: delete the folder and the next agent starts without it.
struct SharedPluginsPage: View {
    let snapshot: DaemonAPI.SharedSnapshot
    @State private var chosenID: String?

    private var folder: String { snapshot.home + "/plugins" }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SharedPageHeader(title: "Plugins", path: folder) {
                        Button("Reveal in Finder") { SharedFiles.reveal(folder) }.buttonStyle(.paper)
                    }
                    if snapshot.plugins.isEmpty {
                        Text("No plugins yet. A plugin is a folder in ~/.agents/plugins, laid out as Claude’s plugins are.")
                            .appText(.fine).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.plugins) { plugin in
                        SharedRow(chosen: plugin.id == chosen?.id,
                                  label: "\(plugin.name), \(Self.contents(plugin).joined(separator: ", ")). \(ReachDots.spoken(snapshot.runtimes, plugin.reach))",
                                  action: { chosenID = plugin.id }) {
                            HStack(spacing: 8) {
                                Text(plugin.name).fontWeight(.semibold).lineLimit(1).fixedSize()
                                ForEach(Self.contents(plugin), id: \.self) { SharedChip(text: $0) }
                                Spacer(minLength: 6)
                                ReachDots(runtimes: snapshot.runtimes, reach: plugin.reach)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(width: 440)
            Divider()
            if let chosen {
                PluginDetail(plugin: chosen, runtimes: snapshot.runtimes)
            } else {
                Text("Choose a plugin").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var chosen: DaemonAPI.Plugin? {
        snapshot.plugins.first { $0.id == chosenID } ?? snapshot.plugins.first
    }

    static func contents(_ plugin: DaemonAPI.Plugin) -> [String] {
        let counts = plugin.contents
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        return [count(counts.skills, "skill", "skills"), count(counts.commands, "command", "commands"),
                count(counts.agents, "agent", "agents"), count(counts.hooks, "hook", "hooks"),
                count(counts.mcpServers, "MCP server", "MCP servers")].compactMap { $0 }
    }
}

private struct PluginDetail: View {
    let plugin: DaemonAPI.Plugin
    let runtimes: [DaemonAPI.RuntimeName]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(plugin.name).appText(.reading).fontWeight(.semibold)
                if let version = plugin.version { SharedChip(text: version) }
            }
            if let description = plugin.description, !description.isEmpty {
                Text(description).appText(.supporting).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plugin.files, id: \.self) { file in
                        HStack(spacing: 8) {
                            Text(file).appText(.code)
                            if file == ".mcp.json", !plugin.serverNames.isEmpty {
                                Text(plugin.serverNames.joined(separator: ", ")).appText(.fine).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(maxHeight: 180)
            .paperRaised(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
            SharedSectionLabel("How each gets it")
            SharedReachList(runtimes: runtimes, reach: plugin.reach)
            Spacer()
            Button("Reveal in Finder") { SharedFiles.reveal(plugin.path) }.buttonStyle(.paper)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
