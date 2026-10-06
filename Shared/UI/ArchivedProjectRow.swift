import AgentsKitCore
import SwiftUI

/// An archived project, with when it was put away, and Bring Back: a row of the sidebar's
/// Archived projects fold on the Mac and on the Remote (#343). What Bring Back does is the
/// app's: each brings the project back through its own host and opens it.
struct ArchivedProjectRow: View {
    let summary: DaemonAPI.ProjectSummary
    /// Its host is not answering, so there is nobody to bring it back.
    var isDisabled = false
    let bringBack: () async -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name).lineLimit(1).foregroundStyle(.secondary)
                if let archivedAt = summary.project.archivedAt {
                    Text("Archived \(archivedAt.formatted(.relative(presentation: .named)))")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Bring Back") {
                Task { await bringBack() }
            }
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            .tint(Paper.accent)
            #endif
            .appText(.fine)
            .disabled(isDisabled)
        }
        .contextMenu {
            Button("Bring Back") {
                Task { await bringBack() }
            }
            .disabled(isDisabled)
        }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            Button("Bring Back") {
                Task { await bringBack() }
            }
            .tint(Paper.accent)
            .disabled(isDisabled)
        }
        #endif
    }
}
