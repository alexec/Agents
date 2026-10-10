import AgentsKitCore
import SwiftUI

/// A new project on one host (#537): a folder there, or a repository cloned into its
/// home. The window's + menu and the page's, per host; the phone cannot see any host's
/// disk, so every folder is chosen the way the window chooses a server's.
enum NewProject: Identifiable, Hashable {
    case folder(HostID)
    case clone(HostID)

    var id: Self { self }
}

/// The + at the head of the sidebar: Add Project… and Clone Project from Git URL…, under
/// each host's name when there is more than one. A host not answering can't take one.
struct NewProjectMenu: View {
    @Environment(RemoteModel.self) private var model
    @Binding var adding: NewProject?

    var body: some View {
        Menu {
            let hosts = model.projectHosts
            ForEach(hosts) { host in
                Section(hosts.count > 1 ? host.title : "") {
                    Button("Add Project…", systemImage: "folder.badge.plus") { adding = .folder(host.id) }
                    Button("Clone Project from Git URL…", systemImage: "arrow.down.doc") { adding = .clone(host.id) }
                }
                .disabled(model.isStale(on: host.id))
            }
        } label: {
            Label("New Project", systemImage: "plus")
        }
    }
}

/// Whichever of the two sheets `adding` names.
struct NewProjectSheet: View {
    let adding: NewProject

    var body: some View {
        switch adding {
        case .folder(let host): FolderPickerSheet(host: host)
        case .clone(let host): CloneProjectSheet(host: host)
        }
    }
}

/// Choose a folder on a host as a project (the window's `RemoteFolderSheet`): a path
/// field, and the folders under it, read with `files/browse` on that host.
private struct FolderPickerSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostID

    @State private var path = "~"
    @State private var listing: DirectoryListing?
    @State private var chosen: URL?
    @State private var problem: String?
    @State private var adding = false

    private var label: String { model.projectHosts.first { $0.id == host }?.title ?? model.hostLabel(host) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("~/src", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { Task { await load(path) } }
                } footer: {
                    if let problem {
                        Text(problem).tinted(.failure)
                    } else {
                        Text("Type a path or open a folder. Tap one to choose it; with none chosen, the folder shown is added.")
                    }
                }
                Section {
                    if let listing, listing.url.path != "/" {
                        let parent = listing.url.deletingLastPathComponent()
                        Button {
                            Task { await load(parent.path(percentEncoded: false)) }
                        } label: {
                            Label(parent.lastPathComponent.isEmpty ? "/" : parent.lastPathComponent,
                                  systemImage: "chevron.left")
                        }
                        .foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        row(entry)
                    }
                    if let listing, listing.isTruncated {
                        Text("\(listing.omitted) more not shown. Type a path to go further.")
                            .appText(.fine).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Choose a folder on \(label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(adding ? "Adding…" : "Add") { Task { await add() } }
                        .disabled(listing == nil || adding)
                }
            }
        }
        .task { await load("~") }
    }

    /// A folder: tapped, it is chosen; its arrow opens it. A file is shown, never chosen.
    private func row(_ entry: DirectoryEntry) -> some View {
        HStack {
            Button {
                chosen = chosen == entry.url ? nil : entry.url
            } label: {
                HStack {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                        .foregroundStyle(entry.isDirectory ? .primary : .tertiary)
                    Spacer()
                    if chosen == entry.url { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!entry.isDirectory)
            if entry.isDirectory {
                Button {
                    Task { await load(entry.url.path(percentEncoded: false)) }
                } label: {
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open \(entry.name)")
            }
        }
        .accessibilityAddTraits(chosen == entry.url ? .isSelected : [])
    }

    /// Folders first, then files, each by name.
    private var entries: [DirectoryEntry] {
        (listing?.entries ?? []).sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func load(_ wanted: String) async {
        switch await model.browse(wanted, on: host) {
        case .success(let listed):
            listing = listed
            path = listed.url.path(percentEncoded: false)
            chosen = nil
            problem = nil
        case .failure(let failure):
            problem = failure.message
        }
    }

    private func add() async {
        guard let folder = chosen ?? listing?.url else { return }
        adding = true
        defer { adding = false }
        if let problem = await model.addProject(folder, on: host) {
            self.problem = problem
        } else {
            dismiss()
        }
    }
}

/// New project from a Git URL (the window's `CloneSheet`): paste it, see where it will
/// go, clone. Held open while the clone runs, since the phone has no row for one under
/// way, and closed when the project is there.
private struct CloneProjectSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostID

    @State private var text = ""
    @State private var cloning = false
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    private var remote: GitRemote? { GitRemote(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://github.com/owner/repository.git", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isFocused)
                        .submitLabel(.go)
                        .onSubmit { Task { await clone() } }
                        .disabled(cloning)
                } footer: {
                    if let problem {
                        Text(problem).tinted(.failure)
                    } else if let remote {
                        Text(host == .mac
                             ? "Clones into ~/\(remote.folderName) and adds it as a project."
                             : "Clones into ~/\(remote.folderName) on \(model.hostLabel(host)) and adds it as a project.")
                    } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Paste an HTTPS or SSH address.")
                    } else {
                        Text("That is not a Git URL this app can clone. Paste an HTTPS or SSH address.")
                            .tinted(.failure)
                    }
                }
                if cloning {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Cloning…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Clone a Git repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Clone") { Task { await clone() } }
                        .disabled(remote == nil || cloning)
                }
            }
        }
        // Not read from the pasteboard, as the window does: here that asks leave to paste
        // every time the sheet opens.
        .onAppear { isFocused = true }
    }

    private func clone() async {
        guard let remote, !cloning else { return }
        cloning = true
        problem = nil
        defer { cloning = false }
        if let problem = await model.cloneProject(url: remote.url, on: host) {
            self.problem = problem
        } else {
            dismiss()
        }
    }
}
