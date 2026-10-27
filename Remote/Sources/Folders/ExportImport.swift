import AgentsKitCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Export… and Import Agents… (#1001), as the Mac's: an agent or a folder's agents as a
/// .tar.gz the person saves with the system's file picker, and one brought back, archived,
/// on a folder's machine, with a busy sheet and Cancel while the host works (#2437). A row's menu is gone once a button in it is pressed, so the
/// picker and what it says are put up from the front window, not from the row.
@MainActor
enum RemoteExportImport {
    /// Made and read with the busy sheet up (#2437), then saved with the picker. One at a time.
    static func export(_ request: DaemonAPI.AgentsExportRequest, on host: MachineRef, model: RemoteModel) {
        guard model.exportImport == nil else { return }
        guard let client = model.hostClient(host) else {
            say("The export did not start", "That machine is not connected.")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString)")
        run(.export, model: model) { progress in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let made = try await AgentsExportTransfer.make(request, on: client)
            try Task.checkCancellation()
            progress.agents = made.agents
            let file = folder.appending(path: made.name)
            try await AgentsExportTransfer.read(made, from: client, into: file, progress: progress.report)
            return {
                let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
                let keeper = PickerEnd { _ in try? FileManager.default.removeItem(at: folder) }
                hold(keeper, for: picker)
                present(picker)
            }
        } failed: { error in
            try? FileManager.default.removeItem(at: folder)
            if let error { say("The export did not finish", error.localizedDescription) }
        }
    }

    /// Import Agents… from a folder's menu: on that folder's machine, into that folder.
    static func importAgents(into summary: DaemonAPI.FolderSummary, model: RemoteModel) {
        guard model.exportImport == nil else { return }
        guard let client = model.hostClient(summary.host) else {
            say("The import did not start", "That machine is not connected.")
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.gzip, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        let keeper = PickerEnd { urls in
            guard let file = urls.first else { return }
            run(.import, model: model) { progress in
                defer { try? FileManager.default.removeItem(at: file) }
                let result = try await AgentsExportTransfer.importFile(file, into: client, folder: summary.folder.folder) { done, whole in
                    progress.report(done, whole)
                    if done >= whole { Task { @MainActor in progress.sent = true } }
                }
                return { say(AgentsExportTransfer.imported(result, into: summary.name), nil) }
            } failed: { error in
                try? FileManager.default.removeItem(at: file)
                if let error { say("The import did not finish", error.localizedDescription) }
            }
        }
        hold(keeper, for: picker)
        present(picker)
    }

    /// Runs `work` with the busy sheet up and as the task its Cancel stops. What `work`
    /// gives back is done once the sheet has gone; `failed` hears the error, nil for a cancel.
    private static func run(_ kind: ExportImportProgress.Kind, model: RemoteModel,
                            _ work: @escaping @MainActor (ExportImportProgress) async throws -> @MainActor () -> Void,
                            failed: @escaping @MainActor (Error?) -> Void) {
        let progress = ExportImportProgress(kind)
        model.exportImport = progress
        let sheet = UIHostingController(rootView: ExportImportProgressView(progress: progress))
        sheet.modalPresentationStyle = .formSheet
        sheet.isModalInPresentation = true
        sheet.sheetPresentationController?.detents = [.custom { _ in 140 }]
        present(sheet)
        progress.task = Task { @MainActor in
            var then: (@MainActor () -> Void)?
            var problem: Error?
            var ended = false
            do {
                then = try await work(progress)
                try Task.checkCancellation()
            } catch is CancellationError {
                ended = true
            } catch {
                problem = Task.isCancelled ? nil : error
                ended = true
            }
            await withCheckedContinuation { done in sheet.dismiss(animated: true) { done.resume() } }
            model.exportImport = nil
            if ended { failed(problem) } else { then?() }
        }
    }

    /// A picker's delegate is weak: the one up now is kept here until it ends.
    private static var keeper: PickerEnd?

    private static func hold(_ end: PickerEnd, for picker: UIDocumentPickerViewController) {
        keeper = end
        picker.delegate = end
    }

    private static func say(_ title: String, _ detail: String?) {
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    /// The front window's top view controller presents it.
    private static func present(_ controller: UIViewController) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        top.present(controller, animated: true)
    }
}

/// The picker's delegate: what was picked, or nothing.
@MainActor
private final class PickerEnd: NSObject, UIDocumentPickerDelegate {
    let done: @MainActor ([URL]) -> Void

    init(_ done: @escaping @MainActor ([URL]) -> Void) { self.done = done }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done([]) }
}

/// Export… in an agent's menu.
struct ExportAgentButton: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        Button("Export…", systemImage: "square.and.arrow.up") {
            RemoteExportImport.export(DaemonAPI.AgentsExportRequest(agentID: agent.id), on: agent.host, model: model)
        }
        // Off while one is on its way, so a second tap makes no second export (#2437).
        .disabled(model.isStale(agent) || model.exportImport != nil)
    }
}

/// Export Agents… and Import Agents… in a folder's menu.
struct ExportImportFolderButtons: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.FolderSummary

    var body: some View {
        Button("Export Agents…", systemImage: "square.and.arrow.up") {
            RemoteExportImport.export(DaemonAPI.AgentsExportRequest(folder: summary.folder.folder), on: summary.host, model: model)
        }
        .disabled(model.isStale(on: summary.host) || model.exportImport != nil)
        Button("Import Agents…", systemImage: "square.and.arrow.down") {
            RemoteExportImport.importAgents(into: summary, model: model)
        }
        .disabled(model.isStale(on: summary.host) || model.exportImport != nil)
    }
}
