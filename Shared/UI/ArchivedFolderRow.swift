import AgentsKitCore
import SwiftUI

/// An archived folder, with when it was put away, Unarchive and Delete…: a row of the
/// sidebar's Archived folders fold on the Mac and on the Remote (#343). Named as a live
/// folder's row is, `server:Folder` on a server (#677). What Unarchive does is the
/// app's: each brings the folder back through its own host and opens it. Delete… is
/// the app's too: each asks first, and deletes through its host.
struct ArchivedFolderRow: View {
    let summary: DaemonAPI.FolderSummary
    /// `SidebarOrder.label`: the host's name before a server's folder.
    let label: String
    /// Its host is not answering, so there is nobody to bring it back.
    var isDisabled = false
    let unarchive: () async -> Void
    /// Ask to delete it (#677). The asking and the deleting are the app's.
    let delete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).lineLimit(1).foregroundStyle(.secondary)
                if let archivedAt = summary.folder.archivedAt {
                    Text("Archived \(archivedAt.formatted(.relative(presentation: .named)))")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Unarchive") {
                Task { await unarchive() }
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
            Button("Unarchive") {
                Task { await unarchive() }
            }
            .disabled(isDisabled)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
                .disabled(isDisabled)
        }
        #if os(iOS)
        .swipeActions(edge: .leading) {
            Button("Unarchive") {
                Task { await unarchive() }
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
