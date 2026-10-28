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
            WaitingForOKBanner(folder: folder)
            // The same strip as over a chat: a prompt here goes to that host too (#83).
            if let summary {
                OfflineStrip(host: summary.host)
                DiskStrip(host: summary.host)
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
                folderMenu
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

    /// The folder's name, as a menu of every folder (#495): New Session at the top of
    /// the sidebar starts in the last one used, and this is where another is chosen.
    private var folderMenu: some View {
        Menu {
            ForEach(SidebarOrder.folders(model.liveFolders, servers: model.hosts.servers), id: \.key) { folder in
                Button {
                    model.showFolder(folder.key)
                } label: {
                    if folder.key == model.selectedFolderKey {
                        Label(label(folder), systemImage: "checkmark")
                    } else {
                        Text(label(folder))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(summary?.name ?? "Folder")
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
        .help("Start the session in another folder")
        .accessibilityLabel("Folder: \(summary?.name ?? "none")")
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
    @ViewBuilder
    private func personaPicker(_ usable: [Persona], picked: Persona?, menu: Bool = false) -> some View {
        let picker = Picker("Persona", selection: Binding<String?>(
            get: { model.draftPersona },
            set: { id in model.choosePersona(usable.first { $0.id == id }) }
        )) {
            Text(Self.noPersona).tag(String?.none)
            ForEach(usable) { persona in
                Text(persona.name).tag(Optional(persona.id))
            }
        }
        if menu {
            picker
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Persona: \(picked?.name ?? Self.noPersona)")
        } else {
            picker
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Persona: \(picked?.name ?? Self.noPersona)")
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

/// Everything in the folder waiting for somebody's OK, as one banner across the top of
/// the pane: plugins new or changed since they were approved, which no agent is given
/// until then, and workflows likewise, which do not run. Review opens the one thing when
/// there is one, and otherwise the place they are listed.
struct WaitingForOKBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    let folder: URL?

    private var plugins: [FolderPlugin] {
        model.plugins(in: folder).filter { $0.awaitingApproval != nil }
    }
    private var workflows: [WorkflowSummary] {
        model.workflows(in: folder).filter { $0.awaitingApproval != nil && !$0.isArchived }
    }

    var body: some View {
        if !plugins.isEmpty || !workflows.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised")
                    .tinted(.attention)
                    .accessibilityHidden(true)
                Text(sentence)
                    .appText(.supporting)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Review…") { review() }
                    .buttonStyle(.paper)
                    .appText(.fine)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.wash)
            .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
            .accessibilityElement(children: .contain)
        }
    }

    private var sentence: String {
        switch (plugins.count, workflows.count) {
        case (1, 0): return "Plugin \(plugins[0].name) is waiting for your OK"
        case (0, 1): return "Workflow \(workflows[0].workflow.name) is waiting for your OK"
        default:
            var parts: [String] = []
            if !plugins.isEmpty { parts.append(plugins.count == 1 ? "1 plugin" : "\(plugins.count) plugins") }
            if !workflows.isEmpty { parts.append(workflows.count == 1 ? "1 workflow" : "\(workflows.count) workflows") }
            let total = plugins.count + workflows.count
            return "\(parts.joined(separator: " and ")) \(total == 1 ? "is" : "are") waiting for your OK"
        }
    }

    /// Plugins first: they are approved on Folder Settings, and a workflow is approved
    /// on its own page, which is one click from the middle column anyway.
    private func review() {
        if !plugins.isEmpty {
            requests.folderSettings = .plugins
        } else if let first = workflows.first {
            model.openWorkflow = first.id
        }
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
