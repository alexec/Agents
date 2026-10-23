import AgentsKitCore
import AppKit
import UniformTypeIdentifiers

/// Export… and Import Agents… (#1001): an agent or a project's agents as a .tar.gz the
/// person saves where they choose, and one brought back, archived, on a project's machine.
/// The host makes and reads the file; the window carries it in parts.
extension AppModel {
    func exportAgent(_ agent: Agent) async {
        await export(DaemonAPI.AgentsExportRequest(agentID: agent.id), on: agent.host)
    }

    func exportProject(_ summary: DaemonAPI.ProjectSummary) async {
        await export(DaemonAPI.AgentsExportRequest(folder: summary.folder), on: summary.host)
    }

    private func export(_ request: DaemonAPI.AgentsExportRequest, on host: HostID) async {
        let client = client(for: host)
        do {
            let made = try await AgentsExportTransfer.make(request, on: client)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = made.name
            panel.allowedContentTypes = [.gzip]
            panel.message = made.agents == 1 ? "Export 1 agent" : "Export \(made.agents) agents"
            guard panel.runModal() == .OK, let target = panel.url else { return }
            try await AgentsExportTransfer.read(made, from: client, into: target)
        } catch {
            say("The export did not finish", describe(error))
        }
    }

    /// Import Agents… from a project's menu: on that project's machine, into that project.
    func importAgents(into summary: DaemonAPI.ProjectSummary) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gzip]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an export of Agents. Its agents come back archived, in \(summary.name)."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let result = try await AgentsExportTransfer.importFile(file, into: client(for: summary.host),
                                                                   folder: summary.folder)
            say(AgentsExportTransfer.imported(result, into: summary.name), nil)
        } catch {
            say("The import did not finish", describe(error))
        }
    }

    private func say(_ title: String, _ detail: String?) {
        let alert = NSAlert()
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        alert.runModal()
    }
}
