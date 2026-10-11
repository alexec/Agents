import AgentsKitCore
import SwiftUI

/// An archived project, with when it was put away, Bring Back and Delete…: a row of the
/// sidebar's Archived projects fold on the Mac and on the Remote (#343). Named as a live
/// project's row is, `server:Project` on a server (#677). What Bring Back does is the
/// app's: each brings the project back through its own host and opens it. Delete… is
/// the app's too: each asks first, and deletes through its host.
struct ArchivedProjectRow: View {
    let summary: DaemonAPI.ProjectSummary
    /// `SidebarOrder.label`: the host's name before a server's project.
    let label: String
    /// Its host is not answering, so there is nobody to bring it back.
    var isDisabled = false
    let bringBack: () async -> Void
    /// Ask to delete it (#677). The asking and the deleting are the app's.
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).lineLimit(1).foregroundStyle(.secondary)
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
            Divider()
            Button("Delete…", role: .destructive, action: delete)
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
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive, action: delete)
                .disabled(isDisabled)
        }
        #endif
    }
}
