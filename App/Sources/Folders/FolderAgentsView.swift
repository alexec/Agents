import AgentsKitCore
import SwiftUI

/// The folder itself, with no session picked: an empty new chat (066, look/ frame A).
///
/// It is laid out as a chat is, with the prompt at the foot of the pane, so starting a
/// session and carrying one on happen in the same place, and sending turns this pane
/// into the session without the bar moving. Above the prompt, the folder's name and
/// where it is, where a chat's transcript would be. The folder's sessions and workflows
/// are under it in the sidebar (#145), and the button to its settings, a sheet
/// (`FolderSettingsSheet`), is in the detail's toolbar. Anything in it waiting for somebody's OK — a plugin, a
/// workflow — is one banner across the top, since no agent gets it until somebody looks.
///
/// The prompt is the chat's own `PromptBar`, not a copy of it — the runtime picker, the
/// options, the folders and servers, attachments, dictation, the lot — in the mode it is
/// in for a new chat, with the folder already set to this folder.
struct FolderAgentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @Environment(WindowRequests.self) private var requests
    /// The folder of the window this is in, when that is a folder's own (#1089): its
    /// folder, whatever the main window has selected.
    @Environment(\.windowFolder) private var windowFolder
    @Binding var selection: UUID?
    /// What the Blobs over the page look at (#987): the prompt, and the pointer while it
    /// has focus.
    @State private var promptFocused = false
    @State private var typed = 0
    @State private var pointer: CGPoint?

    private var folder: URL? { windowFolder?.folder ?? model.selectedFolder }
    private var summary: DaemonAPI.FolderSummary? {
        guard let windowFolder else { return model.selectedFolderSummary }
        return model.liveFolders.first { $0.key == windowFolder }
    }

    var body: some View {
        Group {
            if summary == nil {
                // No folder: one that was selected has gone (a rebuilt server, 043) or there
                // are none yet. A page with a prompt here would start an agent nowhere.
                EmptyState.noFolder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("")
            } else {
                page
            }
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            // The same strip as over a chat: a prompt here goes to that host too (#83).
            if let summary {
                OfflineStrip(host: summary.host)
            }
            // A change to the folder's own files that no session can be asked about (#531).
            if let summary {
                ForEach(model.work.guardedChanges(ofFolder: summary.key)) { change in
                    GuardedChangeQuestion(change: change, key: summary.key)
                        .frame(maxWidth: 720)
                        .padding([.horizontal, .top], 16)
                }
            }
            Spacer(minLength: 24)
            Huddle(promptFocused: promptFocused, pointer: pointer, typed: typed)
                .padding(.bottom, 16)
            heading
            Spacer(minLength: 24)
            // Starts kept for this folder's stopped workspace (#691 US3, layouts.md L6a):
            // the agent each makes opens once the host is up.
            if let summary, case let starts = model.keptStarts(on: summary.host, in: summary.key.folder), !starts.isEmpty {
                VStack(spacing: 10) {
                    ForEach(starts) { KeptPromptRow(kept: $0) }
                }
                .chatColumn()
                .padding(.bottom, 12)
                .environment(\.chatActions, ChatActions(
                    dropKept: { [model] in await model.dropKept($0) },
                    retryKept: { [model] in await model.retryKept($0) },
                    hostName: { [model] in model.hosts.label($0) }))
            }
            // Its own margins, the same as in a chat. The folder is this folder's and
            // not the bar's to change.
            PromptBar(folderIsFixed: true, presence: { promptFocused = $0; typed = $1 })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case let .active(location) = phase { pointer = location } else { pointer = nil }
        }
        .navigationTitle(summary?.name ?? "Folder")
        .onAppear { adopt(folder) }
        .onChange(of: folder) { _, folder in
            adopt(folder)
        }
        // One draft for every window: it follows the one in front (#1089).
        .onChange(of: appearsActive) { _, active in
            if active { adopt(folder, again: true) }
        }
        .task(id: folder) {
            if let folder { await model.refreshPlugins(in: folder) }
        }
    }

    /// Point the prompt at this folder, so what you type starts an agent here.
    private func adopt(_ folder: URL?, again: Bool = false) {
        let window = model.composingWindow
        model.composingWindow = windowFolder
        guard let folder, model.draftCwd != folder || (again && window != windowFolder) else { return }
        model.draftCwd = folder
        Task { await model.loadDraftOptions() }
    }

    /// The name, and where the folder is, in the middle of the empty pane.
    ///
    /// What it has cost is on Folder Settings ▸ General: it is a report, and nobody acts
    /// on it from here. The one thing about the folder that is news here is that it has gone.
    private var heading: some View {
        VStack(spacing: 6) {
            // No menu of folders in a folder's own window: the window is the folder.
            if windowFolder == nil {
                projectMenu
                machineMenu
            } else {
                Text(summary?.name ?? "Folder")
                    .appText(.title).fontWeight(.semibold)
                    .lineLimit(1)
            }
            personaMenu
            if let summary {
                Text(place(summary))
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(summary.folder.folder.path)
                if !summary.exists {
                    Label("Folder is missing", systemImage: "exclamationmark.triangle")
                        .appText(.supporting)
                        .tinted(.failure)
                        .lineLimit(1)
                }
            }
        }
        .multilineTextAlignment(.center)
        .chatColumn()
    }

    /// The project's name, as a menu of every project (#495, #3279): New Session at the top
    /// of the sidebar starts in the last one used, and this is where another is chosen. A
    /// project with one folder is that folder, with its name, as before.
    private var projectMenu: some View {
        let projects = model.newSessionProjects
        let current = NewSessionProject.choice(of: summary?.key, in: projects)
        return Menu {
            ForEach(projects) { project in
                Button {
                    model.showProject(project)
                } label: {
                    if project.id == current?.id {
                        Label(projectLabel(project), systemImage: "checkmark")
                    } else {
                        Text(projectLabel(project))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(current?.name ?? summary?.name ?? "Project")
                    .appText(.title).fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Start the session in another project")
        .accessibilityLabel("Project: \(current?.name ?? summary?.name ?? "none")")
    }

    /// A project with one folder is named as its folder is today: `server:Name` when the
    /// folder is on a server. One with folders on several machines is named alone.
    private func projectLabel(_ project: NewSessionProject.Choice) -> String {
        guard project.hidesMachine, let key = project.folders.first,
              let folder = model.liveFolders.first(where: { $0.key == key }) else { return project.name }
        return label(folder)
    }

    /// On: the machines that have a folder of the project (#3279), this one first. A
    /// stopped machine starts when it is used. Not drawn for a project with one folder.
    @ViewBuilder private var machineMenu: some View {
        if let summary, let project = NewSessionProject.choice(of: summary.key, in: model.newSessionProjects),
           !project.hidesMachine {
            Menu {
                ForEach(project.folders, id: \.self) { key in
                    Button {
                        model.showFolder(key)
                    } label: {
                        if key == summary.key {
                            Label(machineLabel(key, in: project), systemImage: "checkmark")
                        } else {
                            Text(machineLabel(key, in: project))
                        }
                    }
                }
                // The existing Send to ‹machine›… sheet (#1123), not a new flow.
                if model.canSend(from: summary.host), !model.sendTargets.isEmpty {
                    Divider()
                    Menu("Add a Folder on Another Machine") {
                        ForEach(model.sendTargets, id: \.self) { host in
                            Button("Send to \(model.hosts.label(host))…") {
                                requests.sendToHost = SendToHostRequest(folder: summary.folder.folder, from: summary.host,
                                                                        host: host)
                            }
                        }
                    }
                    .disabled(!summary.exists)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("On \(model.hosts.label(summary.host))")
                        .appText(.reading)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Start the session on another machine")
            .accessibilityLabel("On: \(model.hosts.label(summary.host))")
        }
    }

    /// `This Mac`, `devbox (offline)`, `cloud-1 (stopped, starts when used)`; with the path
    /// when the project has two folders on the machine.
    private func machineLabel(_ key: FolderKey, in project: NewSessionProject.Choice) -> String {
        let host = key.host
        var name = model.hosts.label(host)
        if project.folders.filter({ $0.host == host }).count > 1 {
            name += " · \(FolderPlace.path(key.folder, on: host))"
        }
        if model.startsWhenUsed(host) { return "\(name) (stopped, starts when used)" }
        if model.hostUnreachable(host) { return "\(name) (offline)" }
        return name
    }

    /// The kind of session to start (#760), the same control as the folder's name, a
    /// size smaller, on its own line under it (#913). What the picked one is for, and any
    /// persona file that cannot be read, are under it. Not drawn where there are none.
    @ViewBuilder private var personaMenu: some View {
        let usable = model.draftPersonas.filter { $0.problem == nil }
        let broken = model.draftPersonas.filter { $0.problem != nil }
        let picked = usable.first { $0.id == model.draftPersona }
        VStack(spacing: 4) {
            if !model.draftPersonas.isEmpty {
                if !usable.isEmpty {
                    // Centred under the folder when it fits; a menu of them when it does not (#2795).
                    ViewThatFits(in: .horizontal) {
                        personaPicker(usable, picked: picked)
                        personaPicker(usable, picked: picked, menu: true)
                    }
                    .disabled(model.isStarting)
                    .help("Start a kind of session: a persona sets what it names")
                    // What the live pick picked and the word, so the person sees what to change (#4559).
                    if model.draftPersonaAuto {
                        Text(Persona.autoLine(model.draftAutoPick))
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = picked?.description {
                    Text(description)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                ForEach(broken) { persona in
                    Text("\(persona.id).md: \(persona.problem ?? "")")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static let noPersona = "No persona"

    /// Segments, or a menu: the picked one's name and a chevron, where they do not fit (#2795).
    /// No Auto segment (#4721): the prompt's words pick one live until one is picked by hand.
    @ViewBuilder
    private func personaPicker(_ usable: [Persona], picked: Persona?, menu: Bool = false) -> some View {
        let picker = Picker("Persona", selection: Binding<Persona.Segment>(
            get: { Persona.Segment(picked: model.draftPersona) },
            set: { segment in
                switch segment {
                case .none: model.choosePersona(nil)
                case .persona(let id): model.choosePersona(usable.first { $0.id == id })
                }
            }
        )) {
            Text(Self.noPersona).tag(Persona.Segment.none)
            ForEach(usable) { persona in
                Text(persona.name).tag(Persona.Segment.persona(persona.id))
            }
        }
        let shown = picked?.name ?? Self.noPersona
        if menu {
            picker
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Persona: \(shown)")
        } else {
            picker
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Persona: \(shown)")
        }
    }

    private func label(_ folder: DaemonAPI.FolderSummary) -> String {
        SidebarOrder.label(folder) { model.hosts.label($0) }
    }

    /// `~/Agents · this Mac`, or the path and the server's name.
    private func place(_ summary: DaemonAPI.FolderSummary) -> String {
        let machine = summary.host == .mac ? "this Mac" : model.hosts.label(summary.host)
        return "\(FolderPlace.path(summary.folder.folder, on: summary.host)) · \(machine)"
    }
}

/// A part of a page.
struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .appText(.reading).fontWeight(.semibold)
            .padding(.top, 22)
            .padding(.bottom, 2)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
