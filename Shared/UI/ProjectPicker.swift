import AgentsKitCore
import SwiftUI

/// A folder's Project (#2317): the organisation's projects to put it in, New Project… and,
/// for the owner or an admin, Rename Project…. The Mac's Folder Settings ▸ General and the
/// Remote's folder menu show it; on the Remote it is a Form section of its own; the web page's is `Web/src/views/ProjectPicker.tsx`.
struct ProjectPicker: View {
    /// The control plane, which keeps the projects; nil when there is none.
    let control: DaemonClient?
    let summary: DaemonAPI.FolderSummary
    /// Puts the folder in the project, through its own machine: nil, or why not.
    let join: (String) async -> String?

    @State private var projects: [DaemonAPI.Project] = []
    @State private var naming: Naming?
    @State private var name = ""
    @State private var problem: String?
    /// Why the projects could not be read (#2756), so a failed read is not an empty list.
    @State private var notRead: String?
    @State private var isAsking = false

    private enum Naming: Identifiable {
        case new
        case rename(DaemonAPI.Project)

        var id: String {
            switch self {
            case .new: "new"
            case .rename(let project): project.id
            }
        }
    }

    private var current: DaemonAPI.Project? { projects.first { $0.id == summary.project } }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 6) {
            if control == nil {
                Text(ProjectWords.noControlPlane)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    asking(picker.labelsHidden().fixedSize())
                    Menu {
                        Button(ProjectWords.newProject) { ask(.new) }
                        if let current, current.mayChange {
                            Button(ProjectWords.rename) { ask(.rename(current)) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("Project actions")
                    }
                    .fixedSize()
                    .disabled(isAsking)
                }
            }
            if let notRead {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notRead)
                        .appText(.fine)
                        .tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(ProjectWords.tryAgain) { Task { await load() } }
                        .appText(.fine)
                        .disabled(isAsking)
                }
            }
            ForEach(failures, id: \.self) { why in
                Text(why)
                    .appText(.fine)
                    .tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ProjectWords.explanation)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        #else
        // A Form section of its own on the iPhone and iPad (#2757): the Picker as a row, and
        // New Project… and Rename Project… as rows, not in a small menu.
        Section {
            if control == nil {
                Text(ProjectWords.noControlPlane)
                    .foregroundStyle(.secondary)
            } else {
                asking(picker)
                Button(ProjectWords.newProject) { ask(.new) }
                    .disabled(isAsking)
                if let current, current.mayChange {
                    Button(ProjectWords.rename) { ask(.rename(current)) }
                        .disabled(isAsking)
                }
            }
            if let notRead {
                Text(notRead)
                    .tinted(.failure)
                Button(ProjectWords.tryAgain) { Task { await load() } }
                    .disabled(isAsking)
            }
            ForEach(failures, id: \.self) { why in
                Text(why)
                    .tinted(.failure)
            }
        } header: {
            Text(summary.name)
        } footer: {
            Text(ProjectWords.explanation)
        }
        #endif
    }

    private var picker: some View {
        Picker(ProjectWords.title, selection: Binding(get: { summary.project ?? "" },
                                                     set: { id in Task { await pick(id) } })) {
            if summary.project == nil {
                Text("None").tag("")
            } else if let id = summary.project, current == nil {
                // Not listed yet: most often its own project, being made (#2756).
                Text(summary.name).tag(id)
            }
            ForEach(projects) { Text($0.name).tag($0.id) }
        }
        .disabled(isAsking)
    }

    /// Why the folder is not in its project, then why the last change was refused.
    private var failures: [String] { [summary.projectProblem, problem].compactMap { $0 } }

    /// The picker's row reads the projects and asks for a name, so the one view that is
    /// always there with a control plane holds them.
    private func asking(_ content: some View) -> some View {
        content
            .task(id: summary.project) { await load() }
            .alert(naming.map { if case .new = $0 { ProjectWords.newProject } else { ProjectWords.rename } } ?? "",
                   isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }),
                   presenting: naming) { asked in
                TextField(ProjectWords.namePrompt, text: $name)
                Button("Save") { Task { await save(asked) } }
                Button("Cancel", role: .cancel) {}
            }
    }

    private func ask(_ asked: Naming) {
        switch asked {
        case .new: name = summary.name
        case .rename(let project): name = project.name
        }
        problem = nil
        naming = asked
    }

    /// The projects, again. A control plane before projects has none; any other failure
    /// keeps the last list and says why, with Try Again (#2756).
    private func load() async {
        guard let control else { return }
        do {
            projects = try await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                              returning: DaemonAPI.ProjectList.self).projects
            notRead = nil
        } catch {
            notRead = ProjectWords.notRead(error)
            if notRead == nil { projects = [] }
        }
    }

    private func pick(_ id: String) async {
        guard !id.isEmpty, id != summary.project else { return }
        isAsking = true
        defer { isAsking = false }
        problem = await join(id)
    }

    /// New Project… makes one and puts the folder in it; Rename Project… renames.
    private func save(_ asked: Naming) async {
        guard let control else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isAsking = true
        defer { isAsking = false }
        do {
            switch asked {
            case .new:
                let made = try await control.call(DaemonAPI.Method.projectsSet, DaemonAPI.ProjectSet(name: trimmed),
                                                  returning: DaemonAPI.Project.self)
                problem = await join(made.id)
            case .rename(let project):
                _ = try await control.call(DaemonAPI.Method.projectsSet,
                                           DaemonAPI.ProjectSet(id: project.id, name: trimmed),
                                           returning: DaemonAPI.Project.self)
                problem = nil
            }
        } catch {
            problem = PeopleWords.refusal(error)
        }
        await load()
    }
}

/// The Add Folder sheet's Project (#2671): Its Own Project first, so a solo person adds a
/// folder as before (SC-001), then the organisation's projects. A sheet shows it only when
/// `projects(on:)` lists some, so with no control plane, or one before projects, the sheet
/// is as it was. The web page's is in `Web/src/views/NewFolder.tsx`.
struct NewFolderProjectChoice: View {
    let projects: [DaemonAPI.Project]
    /// The project picked; nil is the folder's own.
    @Binding var project: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(ProjectWords.title, selection: $project) {
                Text(ProjectWords.ownProject).tag(String?.none)
                ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
            }
            Text(ProjectWords.addNote)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The organisation's projects; none with no control plane or one before projects.
    static func projects(on control: DaemonClient?) async -> [DaemonAPI.Project] {
        guard let control else { return [] }
        return (try? await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                        returning: DaemonAPI.ProjectList.self))?.projects ?? []
    }
}
