import AgentsKitCore
import SwiftUI

/// Put files into a project's drop box (#231): a folder inside it, if any, then the files
/// chosen in Files. A workflow on `dropbox.file_added` picks them up on the project's
/// host; the Mac's way in is dragging files onto the project's row.
struct DropboxSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: ProjectKey
    let label: String

    @State private var subfolder = ""
    @State private var choosing = false
    @State private var sending = false
    /// What became of the last files chosen: sent, or why one was not.
    @State private var outcome: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Folder (optional)", text: $subfolder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Inside .agents/dropbox/ in \(label), such as review. Empty puts the files at its top.")
                }
                Section {
                    Button {
                        choosing = true
                    } label: {
                        Label(sending ? "Sending…" : "Choose Files…", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(sending)
                } footer: {
                    if let outcome {
                        Text(outcome)
                    } else {
                        Text("Up to 900 KB each. A file with the same name replaces the one there.")
                    }
                }
            }
            .navigationTitle("Drop Box")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty else { return }
                Task { await send(urls) }
            }
        }
    }

    private func send(_ urls: [URL]) async {
        sending = true
        defer { sending = false }
        var sent: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let opened = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if opened { url.stopAccessingSecurityScopedResource() }
            guard let data else {
                outcome = "\(name) could not be read."
                return
            }
            if let problem = await model.putInDropbox(data, name: name, subfolder: subfolder, project: project) {
                outcome = sent.isEmpty ? problem : "Sent \(sent.formatted(.list(type: .and))). \(problem)"
                return
            }
            sent.append(name)
        }
        outcome = "Sent \(sent.formatted(.list(type: .and)))."
    }
}
