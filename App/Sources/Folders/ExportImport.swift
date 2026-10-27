import AgentsKitCore
import AppKit
import UniformTypeIdentifiers

/// Export… and Import Agents… (#1001): an agent or a folder's agents as a .tar.gz the
/// person saves where they choose, and one brought back, archived, on a folder's machine.
/// The host makes and reads the file; the window carries it in parts.
extension AppModel {
    func exportAgent(_ agent: Agent) async {
        await export(DaemonAPI.AgentsExportRequest(agentID: agent.id), on: agent.host)
    }

    func exportFolder(_ summary: DaemonAPI.FolderSummary) async {
        await export(DaemonAPI.AgentsExportRequest(folder: summary.folder.folder), on: summary.host)
    }

    /// Made, saved where the person says, and read, with the busy sheet up while the host
    /// works (#2437); the save panel goes up between. One at a time.
    private func export(_ request: DaemonAPI.AgentsExportRequest, on host: MachineRef) async {
        guard exportImport == nil else { return }
        let client = client(for: host)
        let progress = ExportImportProgress(.export)
        await run(progress) { [self] in
            let made = try await AgentsExportTransfer.make(request, on: client)
            try Task.checkCancellation()
            progress.agents = made.agents
            exportImport = nil
            let panel = NSSavePanel()
            panel.nameFieldStringValue = made.name
            panel.allowedContentTypes = [.gzip]
            panel.message = made.agents == 1 ? "Export 1 agent" : "Export \(made.agents) agents"
            guard panel.runModal() == .OK, let target = panel.url else { return }
            exportImport = progress
            do {
                try await AgentsExportTransfer.read(made, from: client, into: target, progress: progress.report)
            } catch {
                try? FileManager.default.removeItem(at: target) // store-ok: the save panel's own file
                throw error
            }
            exportImport = nil
            if say(AgentsExportTransfer.exported(made.agents), "Saved as \(target.lastPathComponent).",
                   also: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([target]) // store-ok: the save panel's own file
            }
        } failed: { [self] error in
            say("The export did not finish", describe(error))
        }
    }

    /// Import Agents… from a folder's menu: on that folder's machine, into that folder.
    func importAgents(into summary: DaemonAPI.FolderSummary) async {
        guard exportImport == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gzip]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an export of Agents. Its agents come back archived, in \(summary.name)."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let client = client(for: summary.host)
        let progress = ExportImportProgress(.import)
        await run(progress) { [self] in
            let result = try await AgentsExportTransfer.importFile(file, into: client, folder: summary.folder.folder) { done, whole in
                progress.report(done, whole)
                if done >= whole { Task { @MainActor in progress.sent = true } }
            }
            exportImport = nil
            say(AgentsExportTransfer.imported(result, into: summary.name), nil)
        } failed: { [self] error in
            say("The import did not finish", describe(error))
        }
    }

    /// Runs `work` as the task Cancel stops; the sheet goes when it ends. A cancel says nothing.
    private func run(_ progress: ExportImportProgress, _ work: @escaping @MainActor () async throws -> Void,
                     failed: @escaping @MainActor (Error) -> Void) async {
        exportImport = progress
        let task = Task { @MainActor in
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                exportImport = nil
                if !Task.isCancelled { failed(error) }
            }
            exportImport = nil
        }
        progress.task = task
        await task.value
    }

    /// An alert; with `also`, a second button, and whether it was the one pressed.
    @discardableResult
    private func say(_ title: String, _ detail: String?, also: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        if let detail { alert.informativeText = detail }
        alert.addButton(withTitle: "OK")
        if let also { alert.addButton(withTitle: also) }
        return alert.runModal() == .alertSecondButtonReturn
    }
}
