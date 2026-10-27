import AgentsKitCore
import SwiftUI

/// A folder's Project (#2317): the organisation's projects to put it in, New Project… and,
/// for the owner or an admin, Rename Project…. The Mac's Folder Settings ▸ General and the
/// Remote's folder menu show it; the web page's is `Web/src/views/ProjectPicker.tsx`.
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
        VStack(alignment: .leading, spacing: 6) {
            if control == nil {
                Text(ProjectWords.noControlPlane)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Picker(ProjectWords.title, selection: Binding(get: { summary.project ?? "" },
                                                                 set: { id in Task { await pick(id) } })) {
                        if summary.project == nil {
                            Text("None").tag("")
                        } else if let id = summary.project, current == nil {
                            Text(ProjectWords.unknown(id)).tag(id)
                        }
                        ForEach(projects) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(isAsking)
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
            if let why = summary.projectProblem {
                Text(why)
                    .appText(.fine)
                    .tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem)
                    .appText(.fine)
                    .tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ProjectWords.explanation)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    /// The projects, again. A control plane before projects has none.
    private func load() async {
        guard let control else { return }
        projects = (try? await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                            returning: DaemonAPI.ProjectList.self))?.projects ?? []
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
