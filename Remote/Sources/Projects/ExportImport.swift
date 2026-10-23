import AgentsKitCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Export… and Import Agents… (#1001), as the Mac's: an agent or a project's agents as a
/// .tar.gz the person saves with the system's file picker, and one brought back, archived,
/// on a project's machine. A row's menu is gone once a button in it is pressed, so the
/// picker and what it says are put up from the front window, not from the row.
@MainActor
enum RemoteExportImport {
    static func export(_ request: DaemonAPI.AgentsExportRequest, on host: HostID, model: RemoteModel) {
        guard let client = model.hostClient(host) else {
            say("The export did not start", "That machine is not connected.")
            return
        }
        Task {
            let folder = FileManager.default.temporaryDirectory.appending(path: "Export-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let made = try await AgentsExportTransfer.make(request, on: client)
                let file = folder.appending(path: made.name)
                try await AgentsExportTransfer.read(made, from: client, into: file)
                let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
                let keeper = PickerEnd { _ in try? FileManager.default.removeItem(at: folder) }
                hold(keeper, for: picker)
                present(picker)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                say("The export did not finish", error.localizedDescription)
            }
        }
    }

    /// Import Agents… from a project's menu: on that project's machine, into that project.
    static func importAgents(into summary: DaemonAPI.ProjectSummary, model: RemoteModel) {
        guard let client = model.hostClient(summary.host) else {
            say("The import did not start", "That machine is not connected.")
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.gzip, .data], asCopy: true)
        picker.allowsMultipleSelection = false
        let keeper = PickerEnd { urls in
            guard let file = urls.first else { return }
            Task {
                defer { try? FileManager.default.removeItem(at: file) }
                do {
                    let result = try await AgentsExportTransfer.importFile(file, into: client, folder: summary.folder)
                    say(AgentsExportTransfer.imported(result, into: summary.name), nil)
                } catch {
                    say("The import did not finish", error.localizedDescription)
                }
            }
        }
        hold(keeper, for: picker)
        present(picker)
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
        .disabled(model.isStale(agent))
    }
}

/// Export Agents… and Import Agents… in a project's menu.
struct ExportImportProjectButtons: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        Button("Export Agents…", systemImage: "square.and.arrow.up") {
            RemoteExportImport.export(DaemonAPI.AgentsExportRequest(folder: summary.folder), on: summary.host, model: model)
        }
        .disabled(model.isStale(on: summary.host))
        Button("Import Agents…", systemImage: "square.and.arrow.down") {
            RemoteExportImport.importAgents(into: summary, model: model)
        }
        .disabled(model.isStale(on: summary.host))
    }
}
