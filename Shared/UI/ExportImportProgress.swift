import AgentsKitCore
import SwiftUI

/// An Export… or Import Agents… on its way (#2437): what it is doing and how far, and the
/// task that Cancel stops. One at a time: Export… and Import Agents… are off while it runs,
/// so a second tap makes no second export. The Mac and the Remote each keep one and draw
/// it with `ExportImportProgressView`.
@MainActor
@Observable
final class ExportImportProgress: Identifiable {
    enum Kind { case export, `import` }

    let id = UUID()
    let kind: Kind
    /// The export's agents, once the host has made it and said.
    var agents: Int?
    /// Bytes moved of the whole; nil while the host makes or imports, which says no more.
    var fraction: Double?
    /// The import's parts are all sent, and the host is bringing the agents back.
    var sent = false
    /// What Cancel stops.
    var task: Task<Void, Never>?

    init(_ kind: Kind) {
        self.kind = kind
    }

    var line: String {
        switch kind {
        case .export: AgentsExportTransfer.exporting(agents)
        case .import: AgentsExportTransfer.importing(sent: sent)
        }
    }

    /// A transfer's progress callback, which may come from any thread, set here.
    nonisolated var report: AgentsExportTransfer.Progress {
        { [weak self] done, whole in
            Task { @MainActor in self?.fraction = whole > 0 ? Double(done) / Double(whole) : nil }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// The busy sheet: the line, a bar (a spinner while there is nothing to count), and Cancel.
struct ExportImportProgressView: View {
    let progress: ExportImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.line).appText(.reading).fontWeight(.semibold)
            if let fraction = progress.fraction, !progress.sent {
                ProgressView(value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 360)
        .accessibilityElement(children: .contain)
    }
}
