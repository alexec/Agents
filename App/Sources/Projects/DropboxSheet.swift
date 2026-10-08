import AgentsKitCore
import SwiftUI

/// Put files into a project's drop box (#231), inside a folder of it when one is named:
/// the Mac's way to choose that folder, which a drag onto the project's row (always the
/// drop box's top) cannot. Files are chosen, or dragged onto the sheet. A workflow on
/// `dropbox.file_added` picks them up on the project's host.
struct DropboxSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: ProjectKey

    @State private var subfolder = ""
    @State private var choosing = false
    @State private var sending = false
    @State private var isTargeted = false
    /// What became of the last files sent, while nothing has gone wrong.
    @State private var sent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Put Files in Drop Box")
                .appText(.reading).fontWeight(.semibold)
            TextField("Folder (optional)", text: $subfolder)
                .textFieldStyle(.roundedBorder)
            Text("Inside .agents/dropbox/ in \(project.folder.lastPathComponent), such as review. Empty puts the files at its top.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(sending ? "Sending…" : sent ?? "Drag files here, or choose them. A file with the same name replaces the one there.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 64)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .background(isTargeted ? Paper.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4), style: .init(dash: [4])))
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter { !$0.hasDirectoryPath }
                    guard !files.isEmpty, !sending else { return false }
                    Task { await send(files) }
                    return true
                } isTargeted: { isTargeted = $0 }
            HStack {
                Button("Choose Files…") { choosing = true }
                    .disabled(sending)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task { await send(urls) }
        }
    }

    private func send(_ files: [URL]) async {
        sending = true
        sent = nil
        // A chosen file is the panel's to lend; a dragged one opens nothing and needs none.
        let opened = files.filter { $0.startAccessingSecurityScopedResource() }
        let ok = await model.putInDropbox(files, subfolder: subfolder, project: project)
        opened.forEach { $0.stopAccessingSecurityScopedResource() }
        sending = false
        // A file that could not go is the window's alert, as a drag's is.
        if ok { sent = "Sent \(files.map(\.lastPathComponent).formatted(.list(type: .and)))." }
    }
}
