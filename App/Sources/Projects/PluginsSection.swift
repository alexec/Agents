import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// A project's plugins, under its workflows (security review, S2).
///
/// A plugin in `.agents/plugins` can carry hooks and MCP servers that a runtime runs by
/// itself, so one that is new or has changed is kept out of every session until the person
/// says so, here — the way a workflow file waits on its row. Every plugin is listed, not
/// only the waiting ones, so the section says what this project's agents are being handed.
/// Absent on a project with no plugins.
struct PluginsSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?
    /// The project page hides the section when there is nothing to approve or list.
    /// Configuration always shows it, with a line when the folder is empty.
    var showsEmptyState = false

    private var plugins: [ProjectPlugin] { model.plugins(in: folder) }

    var body: some View {
        Group {
            if !plugins.isEmpty || showsEmptyState {
                SectionHeading(title: "Plugins")
                Text("In .agents/plugins, committed with the project. A new or changed one waits until you approve it.")
                    .appText(.fine).foregroundStyle(.secondary)
                    .padding(.leading, 2).padding(.bottom, 4)
                if plugins.isEmpty {
                    Text("No plugins in this project yet.")
                        .appText(.supporting).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperRow()
                }
                ForEach(plugins) { plugin in
                    PluginRow(plugin: plugin)
                }
            }
        }
        // Asked for when the page opens; `plugins/changed` keeps it current after that,
        // including when a session finds one waiting.
        .task(id: folder) {
            if let folder { await model.refreshPlugins(in: folder) }
        }
    }
}

/// One plugin: its name, what it brings, and — when it is new or has changed since it was
/// approved — that it is waiting, with the two things to do about that: look, and approve.
private struct PluginRow: View {
    @Environment(AppModel.self) private var model
    let plugin: ProjectPlugin

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: plugin.awaitingApproval == nil ? "puzzlepiece.extension" : "hand.raised")
                .appText(.reading)
                .foregroundStyle((plugin.awaitingApproval == nil ? StateTint.none : .attention).style(or: .secondary))
                .accessibilityLabel(plugin.awaitingApproval == nil ? "Approved" : "Waiting for your OK")
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)
                Text(carries)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let waiting = plugin.awaitingApproval {
                    Text((waiting.isNew ? "New" : "Changed since you approved it")
                         + " — waiting for your OK. No agent is given it until then.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([plugin.folder])
                }
                .buttonStyle(.paper)
                .appText(.fine)
                if plugin.awaitingApproval != nil {
                    Button("Approve") { Task { await model.approvePlugin(plugin) } }
                        .buttonStyle(.paper)
                        .appText(.fine)
                        .help("Give this plugin to this project's agents as its folder now reads")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRow()
        .accessibilityElement(children: .contain)
    }

    /// What it brings, in a few words; hooks and MCP servers first, since those run.
    private var carries: String {
        plugin.carries.isEmpty ? "Nothing that runs by itself" : plugin.carries.joined(separator: ", ")
    }
}
