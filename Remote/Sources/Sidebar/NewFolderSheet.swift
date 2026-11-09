import AgentsKitCore
import SwiftUI

/// The **+** over the sidebar's folders (#4036), as the window's File ▸ Add Folder… and
/// Clone Git URL… and the page's + menu: per machine, this Mac first. A machine that is
/// offline cannot take one. The folder goes to its default project; Connect your tools stays
/// on the Mac and the web.
struct NewFolderMenu: View {
    @Environment(RemoteModel.self) private var model
    @State private var adding: NewFolderSheet.Kind?

    var body: some View {
        let machines = model.folderMachines
        Menu {
            ForEach(machines) { machine in
                if machines.count > 1 {
                    Section(machine.offline ? "\(machine.title) — Offline" : machine.title) {
                        items(for: machine)
                    }
                } else {
                    items(for: machine)
                }
            }
        } label: {
            Label("New Folder", systemImage: "plus")
        }
        .accessibilityHint("Adds a folder on a machine, or clones one from a Git URL")
        .sheet(item: $adding) { kind in
            NewFolderSheet(kind: kind)
        }
    }

    @ViewBuilder private func items(for machine: RemoteModel.HostSection) -> some View {
        Button("Add Folder…", systemImage: "folder.badge.plus") { adding = .folder(machine.id, machine.title) }
            .disabled(machine.offline)
        Button("Clone Git URL…", systemImage: "arrow.down.circle") { adding = .clone(machine.id, machine.title) }
            .disabled(machine.offline)
    }
}

/// Add Folder… or Clone Git URL… on one machine (#4036): the window's RemoteFolderSheet and
/// CloneSheet, as the page's dialogs (#115). The phone cannot see any machine's disk, so a
/// folder is chosen over `files/browse`.
struct NewFolderSheet: View {
    enum Kind: Identifiable, Hashable {
        case folder(MachineRef, String)
        case clone(MachineRef, String)

        var id: Self { self }
        var host: MachineRef {
            switch self { case .folder(let host, _), .clone(let host, _): host }
        }
        var label: String {
            switch self { case .folder(_, let label), .clone(_, let label): label }
        }
    }

    let kind: Kind

    var body: some View {
        NavigationStack {
            switch kind {
            case .folder: AddFolderForm(host: kind.host, label: kind.label)
            case .clone: CloneFolderForm(host: kind.host, label: kind.label)
            }
        }
    }
}

/// A path field and the folders under it: tap one to go into it, Add to add the one shown.
private struct AddFolderForm: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: MachineRef
    let label: String

    @State private var path = "~"
    @State private var listing: DirectoryListing?
    @State private var problem: String?
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                TextField("~/src", text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await load(path) } }
                    .accessibilityLabel("Folder")
            } footer: {
                if let problem {
                    Text(problem).tinted(.failure)
                } else {
                    Text("Type a path or tap into a folder. Files are shown but can’t be added.")
                }
            }
            if let listing {
                Section {
                    if listing.url.path != "/" {
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
                        if entry.isDirectory {
                            Button {
                                Task { await load(entry.url.path(percentEncoded: false)) }
                            } label: {
                                Label(entry.name, systemImage: "folder")
                            }
                            .foregroundStyle(.primary)
                        } else {
                            Label(entry.name, systemImage: "doc")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Add Folder on \(label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isAdding {
                    ProgressView()
                } else {
                    Button("Add") { Task { await add() } }
                        .disabled(listing == nil)
                }
            }
        }
        .task { await load("~") }
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
            let listed = try await model.browse(wanted, on: host)
            listing = listed
            path = listed.url.path(percentEncoded: false)
            problem = nil
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = "\(label) is not answering."
        }
    }

    private func add() async {
        guard let folder = listing?.url else { return }
        isAdding = true
        problem = await model.addFolder(folder, on: host)
        isAdding = false
        if problem == nil { dismiss() }
    }
}

/// Paste a Git URL, see where it will go, clone. The sheet waits for the clone, which the
/// host finishes even when the sheet is closed: the folder then appears in the sidebar.
private struct CloneFolderForm: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: MachineRef
    let label: String

    @State private var text = ""
    @State private var problem: String?
    @State private var isCloning = false
    @FocusState private var isFocused: Bool

    private var remote: GitRemote? { GitRemote(text) }

    var body: some View {
        Form {
            Section {
                TextField("https://github.com/owner/repository.git", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isFocused)
                    .onSubmit { Task { await clone() } }
                    .disabled(isCloning)
                    .accessibilityLabel("Git URL")
            } footer: {
                note
            }
        }
        .navigationTitle("Clone on \(label)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isCloning ? "Close" : "Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isCloning {
                    ProgressView()
                } else {
                    Button("Clone") { Task { await clone() } }
                        .disabled(remote == nil)
                }
            }
        }
        .onAppear { isFocused = true }
    }

    @ViewBuilder private var note: some View {
        if let problem {
            Text(problem).tinted(.failure)
        } else if isCloning {
            Text("Cloning… The folder appears in the sidebar when it is done, also if you close this.")
        } else if let remote {
            Text(host == .mac ? "Clones into ~/\(remote.folderName) and adds it as a folder."
                 : "Clones into ~/\(remote.folderName) on \(label) and adds it as a folder.")
        } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Paste an HTTPS or SSH address.")
        } else {
            Text("That is not a Git URL this app can clone. Paste an HTTPS or SSH address.").tinted(.failure)
        }
    }

    private func clone() async {
        guard let remote, !isCloning else { return }
        isCloning = true
        problem = nil
        problem = await model.cloneFolder(remote.url, on: host)
        isCloning = false
        if problem == nil { dismiss() }
    }
}
