import AgentsKitCore
import SwiftUI

/// An archived project, with when it was put away, Bring Back and Delete…: a row of the
/// sidebar's Archived projects fold on the Mac and on the Remote (#343). What each does
/// is the app's: Bring Back brings the project back through its own host and opens it;
/// Delete, once confirmed, deletes it there and answers with a refusal or nil (#677).
struct ArchivedProjectRow: View {
    let summary: DaemonAPI.ProjectSummary
    /// What the live rows call it: `server:Project` on a server (#145, #677).
    let label: String
    /// Its host is not answering, so there is nobody to bring it back.
    var isDisabled = false
    let bringBack: () async -> Void
    let delete: () async -> String?

    @State private var deleting = false
    @State private var cannotDelete: String?

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
            Button("Delete…", role: .destructive) { deleting = true }
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
            Button("Delete…", role: .destructive) { deleting = true }
                .disabled(isDisabled)
        }
        #endif
        .confirmationDialog(DeletionWords.confirmProjectTitle(label), isPresented: $deleting,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { cannotDelete = await delete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DeletionWords.confirmProjectMessage)
        }
        .alert("This project cannot be deleted yet",
               isPresented: Binding(get: { cannotDelete != nil }, set: { if !$0 { cannotDelete = nil } })) {
            Button("OK") {}
        } message: {
            Text(cannotDelete ?? "")
        }
    }
}
