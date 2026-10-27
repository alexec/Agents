import AgentsKitCore
import SwiftUI

/// Choose a folder on a server as a folder (037, wireframes/mac-new-folder.svg B).
///
/// The Mac's own folder picker cannot see a server, so this stands in for it: a path
/// field, and the folders under it, read with `files/browse` on that server.
struct RemoteFolderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: MachineRef

    @State private var path = "~"
    @State private var listing: DirectoryListing?
    @State private var chosen: URL?
    @State private var problem: String?
    /// The Project picked (#2671); nil is the folder's own.
    @State private var project: String?
    @State private var projects: [DaemonAPI.Project] = []

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
                Text(problem).appText(.fine).tinted(.failure)
            } else {
                Text("Type a path or click into a folder. Files are shown but can’t be chosen.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            if !projects.isEmpty {
                NewFolderProjectChoice(projects: projects, project: $project)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add as folder") {
                    let folder = chosen ?? listing?.url
                    dismiss()
                    if let folder { Task { await model.addFolder(folder, on: host, project: project) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(listing == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await load(model.hosts.host(host)?.facts?.home ?? "~") }
        .task { projects = await NewFolderProjectChoice.projects(on: model.controlRequests) }
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
