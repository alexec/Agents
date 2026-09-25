import AgentsKit
import SwiftUI

/// Choose a folder on a server as a project (037, wireframes/mac-new-project.svg B).
///
/// The Mac's own folder picker cannot see a server, so this stands in for it: a path
/// field, and the folders under it, read with `files/browse` on that server.
struct RemoteFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostID

    @State private var path = "~"
    @State private var listing: DirectoryListing?
    @State private var chosen: URL?
    @State private var problem: String?

    private var label: String { model.hosts.label(host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a folder on \(label)").appText(.reading).fontWeight(.semibold)
            TextField("~/src", text: $path)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await load(path) } }
            List(selection: $chosen) {
                if let listing, listing.url.path != "/" {
                    Button {
                        Task { await load(listing.url.deletingLastPathComponent().path) }
                    } label: {
                        Label(listing.url.deletingLastPathComponent().lastPathComponent.isEmpty
                              ? "/" : listing.url.deletingLastPathComponent().lastPathComponent,
                              systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    Text(entry.name)
                        .foregroundStyle(entry.isDirectory ? .primary : .tertiary)
                        .tag(entry.url)
                        .selectionDisabled(!entry.isDirectory)
                        .onTapGesture(count: 2) {
                            guard entry.isDirectory else { return }
                            Task { await load(entry.url.path) }
                        }
                }
            }
            .frame(height: 260)
            if let problem {
                Text(problem).appText(.fine).foregroundStyle(.red)
            } else {
                Text("Type a path or click into a folder. Files are shown but can’t be chosen.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add as project") {
                    let folder = chosen ?? listing?.url
                    dismiss()
                    if let folder { Task { await model.addProject(folder, on: host) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(listing == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load(model.hosts.host(host)?.facts?.home ?? "~") }
    }

    /// Folders first, then files, each by name.
    private var entries: [DirectoryEntry] {
        (listing?.entries ?? []).sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func load(_ wanted: String) async {
        do {
            let listed = try await model.client(for: host).call(
                DaemonAPI.Method.filesBrowse, DaemonAPI.FilesBrowseRequest(path: wanted),
                returning: DirectoryListing.self)
            listing = listed
            path = listed.url.path(percentEncoded: false)
            chosen = nil
            problem = nil
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = "\(label) is offline"
        }
    }
}
