import AgentsKit
import SwiftUI

/// A project's own skills, on its page between Workflows and Worktrees (059, look/ frame D):
/// what the project gives every agent working in it. They live in `.agents/skills`, which is
/// committed, so the line under the heading says a skill added here reaches everyone who
/// clones the project. Add skill… opens the catalogue sheet pointed at this project.
///
/// Not drawn for a project on a server: listing a host's folders comes with a later slice
/// (research R10).
struct ProjectSkillsSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?

    @State private var skills: [DaemonAPI.ListedSkill] = []
    @State private var runtimes: [DaemonAPI.RuntimeName] = []
    @State private var adding = false
    @State private var updates: [String: DaemonAPI.UpdateState] = [:]
    @State private var updating: String?

    private var onMac: Bool { model.selectedProjectKey?.host == .mac }

    var body: some View {
        if let folder, onMac {
            heading(folder)
            Text("In .agents/skills, committed with the project: everyone who clones it gets these.")
                .appText(.fine).foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.bottom, 4)
            if skills.isEmpty {
                Text("No skills in this project yet.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperRow()
            } else {
                ForEach(skills) { skill in
                    ProjectSkillRow(skill: skill, folder: folder,
                                    hasUpdate: SharedSkillsPage.available(updates[skill.name]),
                                    update: { updating = skill.name },
                                    changed: { Task { await load(folder) } })
                }
            }
            Color.clear.frame(height: 0)
                .task(id: folder) { await load(folder) }
                .sheet(item: Binding(get: { updating.map(UpdateTarget.init) }, set: { updating = $0?.name })) { target in
                    UpdateSkillSheet(name: target.name, destination: .project(folder: folder.path), runtimes: runtimes,
                                     onUpdated: { Task { await load(folder) } })
                }
                .sheet(isPresented: $adding) {
                    AddSkillSheet(destination: .project(folder: folder.path), runtimes: runtimes,
                                  installed: Set(skills.map(\.name)),
                                  onAdded: { Task { await load(folder) } })
                }
        }
    }

    private func heading(_ folder: URL) -> some View {
        HStack(spacing: 8) {
            SectionHeading(title: "Skills")
                .fixedSize()
            if !skills.isEmpty {
                SharedChip(text: "\(skills.count)").padding(.top, 20)
            }
            Spacer()
            Group {
                Button("Reveal in Finder") {
                    let skillsFolder = folder.appending(path: ".agents/skills")
                    SharedFiles.reveal(FileManager.default.fileExists(atPath: skillsFolder.path) ? skillsFolder.path : folder.path)
                }
                .buttonStyle(.paper)
                Button("Add skill…") { adding = true }.buttonStyle(.paperProminent)
            }
            .padding(.top, 20)
        }
    }

    private func load(_ folder: URL) async {
        if let fresh = await model.projectSkills(folder) { skills = fresh }
        if skills.contains(where: { $0.managed != nil }),
           let fresh = await model.skillUpdates(at: .project(folder: folder.path)) { updates = fresh }
        if runtimes.isEmpty, let snapshot = await model.sharedSnapshot() { runtimes = snapshot.runtimes }
    }
}

/// One of a project's skills: its name and description, and where it came from when a
/// catalogue gave it.
private struct ProjectSkillRow: View {
    @Environment(AppModel.self) private var model
    let skill: DaemonAPI.ListedSkill
    let folder: URL
    var hasUpdate = false
    var update: () -> Void = {}
    var changed: () -> Void = {}
    @State private var confirmingRemove = false
    @State private var failure: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(skill.name).appText(.reading).fontWeight(.semibold).lineLimit(1).fixedSize()
            if skill.managed != nil { SharedChip(text: "skills.sh", tone: .source) }
            if hasUpdate { SharedChip(text: "update", tone: .attention) }
            Text(failure ?? detail).appText(.supporting)
                .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(SharedInk.attention))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            // Only for a skill a lock names; the project's own are the person's to change.
            if skill.managed != nil {
                if hasUpdate { Button("Update…", action: update).buttonStyle(.paperProminent).appText(.fine) }
                Button("Remove") { confirmingRemove = true }.buttonStyle(.paper).appText(.fine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRow()
        .help(skill.folder)
        .accessibilityElement(children: .contain)
        .confirmationDialog("Move \(skill.name) to the Trash?", isPresented: $confirmingRemove) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    if let error = await model.removeSkill(skill.name, at: .project(folder: folder.path)) {
                        failure = CatalogErrorWords.sentence(error)
                    } else {
                        changed()
                    }
                }
            }
        } message: {
            Text("Agents in this project won't have it after that. The removal shows in the project's changes, uncommitted.")
        }
    }

    private var detail: String {
        if let managed = skill.managed {
            return [managed.source, managed.commit.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · ")
        }
        return skill.description ?? ""
    }
}
