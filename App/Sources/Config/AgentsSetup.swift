import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import AppKit
import SwiftUI

/// Where a set of instructions, skills, MCP servers and plugins lives.
/// Yours is `~/.agents`. A project's is `<project>/.agents`, except instructions,
/// which are the project's `AGENTS.md` (the file agents read first).
enum AgentsPlace: Equatable {
    case you
    case project(URL)

    var destination: DaemonAPI.SkillDestination {
        switch self {
        case .you: .personal
        case .project(let folder): .project(folder: folder.path)
        }
    }

    var explainer: String {
        switch self {
        case .you:
            "Yours, in ~/.agents. Every agent you start gets them, in every project."
        case .project:
            "This project's, in its .agents folder. It is committed, so everyone who clones the project gets it. Secrets stay in your own secrets.env."
        }
    }

    var mcpNote: String {
        switch self {
        case .you:
            "In ~/.agents/mcp.json. A secret is named here and kept in ~/.agents/secrets.env."
        case .project:
            "In .agents/mcp.json, committed with the project. Secrets aren't: it names them, and each person sets their own."
        }
    }

    var skillsNote: String {
        switch self {
        case .you: "In ~/.agents/skills. Every agent you start has these."
        case .project: "In .agents/skills, committed with the project. Everyone who clones it gets these."
        }
    }
}

/// One setup section in Settings, where the page is already chosen in the rail.
struct AgentsSetupPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The four things both Settings ▸ Shared and a project's configuration page set up.
struct AgentsSetupView: View {
    var place: AgentsPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(place.explainer)
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AgentsInstructionsSection(place: place)
            AgentsSkillsSection(place: place)
            ProjectMCPSection(place: place)
            AgentsPluginsSection(place: place)
        }
    }
}

// MARK: - Instructions

struct AgentsInstructionsSection: View {
    @Environment(AppModel.self) private var model
    var place: AgentsPlace
    @State private var path = ""
    @State private var text = ""
    @State private var exists = false

    /// Whose disk the file is on: this Mac's host for yours, the project's host for a project's.
    private var host: HostID {
        if case .project = place { return model.selectedProjectHost }
        return .mac
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "Instructions").fixedSize()
                Spacer()
                if !path.isEmpty {
                    Button(exists ? "Edit AGENTS.md" : "Write AGENTS.md") {
                        Task {
                            await ensureFile()
                            model.open(URL(filePath: path), on: host)
                        }
                    }
                    .buttonStyle(.paper)
                    .padding(.top, 20)
                }
            }
            Text(note)
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(text.isEmpty ? "No AGENTS.md yet." : text)
                .appText(.supporting)
                .textSelection(.enabled)
                .lineLimit(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule, lineWidth: 1))
        }
        .task(id: place) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
    }

    private var note: String {
        switch place {
        case .you:
            "Your AGENTS.md in ~/.agents. The app links it into the file each runtime reads."
        case .project:
            "AGENTS.md at the top of the project. Agents read it first."
        }
    }

    private func load() async {
        path = await resolvedPath()
        guard !path.isEmpty else { text = ""; exists = false; return }
        let read = await model.readText(URL(filePath: path), on: host)
        exists = read != nil
        text = read ?? ""
    }

    private func resolvedPath() async -> String {
        switch place {
        case .project(let folder):
            return folder.appending(path: "AGENTS.md").path
        case .you:
            guard let snapshot = await model.sharedSnapshot() else { return "" }
            return snapshot.instructions?.path ?? snapshot.home + "/AGENTS.md"
        }
    }

    private func ensureFile() async {
        guard !exists else { return }
        let url = URL(filePath: path)
        let starter = switch place {
        case .you: "# Personal instructions\n\nHow you like to work, for every agent the app starts.\n"
        case .project: "# Project instructions\n\nHow to work in this project.\n"
        }
        if await model.saveText(starter, to: url, on: host, onlyIfAbsent: true) {
            exists = true
            text = starter
        }
    }
}

// MARK: - Skills

struct AgentsSkillsSection: View {
    @Environment(AppModel.self) private var model
    var place: AgentsPlace

    @State private var skills: [DaemonAPI.ListedSkill] = []
    @State private var runtimes: [DaemonAPI.RuntimeName] = []
    @State private var adding = false
    @State private var updates: [String: DaemonAPI.UpdateState] = [:]
    @State private var updating: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionHeading(title: "Skills").fixedSize()
                if !skills.isEmpty { SharedChip(text: "\(skills.count)").padding(.top, 20) }
                Spacer()
                Button("Add skill…") { adding = true }
                    .buttonStyle(.paperProminent)
                    .padding(.top, 20)
            }
            Text(place.skillsNote)
                .appText(.fine).foregroundStyle(.secondary)
            if skills.isEmpty {
                Text(place == .you ? "No skills of your own yet." : "No skills in this project yet.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperRow()
            } else {
                ForEach(skills) { skill in
                    SetupSkillRow(skill: skill, place: place,
                                  hasUpdate: Self.available(updates[skill.name]),
                                  update: { updating = skill.name },
                                  changed: { Task { await load() } })
                }
            }
        }
        .task(id: place) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
        .sheet(item: Binding(get: { updating.map(UpdateTarget.init) }, set: { updating = $0?.name })) { target in
            UpdateSkillSheet(name: target.name, destination: place.destination, runtimes: runtimes,
                             onUpdated: { Task { await load() } })
        }
        .sheet(isPresented: $adding) {
            AddSkillSheet(destination: place.destination, runtimes: runtimes,
                          installed: Set(skills.filter { $0.managed != nil }.map(\.name)),
                          onAdded: { Task { await load() } })
        }
    }

    static func available(_ state: DaemonAPI.UpdateState?) -> Bool {
        if case .available? = state { return true }
        return false
    }

    private func load() async {
        if let fresh = await model.skills(at: place.destination) { skills = fresh }
        if skills.contains(where: { $0.managed != nil }),
           let fresh = await model.skillUpdates(at: place.destination) { updates = fresh }
        if runtimes.isEmpty, let snapshot = await model.sharedSnapshot() { runtimes = snapshot.runtimes }
    }
}

/// A skill to update, as a sheet's item.
struct UpdateTarget: Identifiable {
    let name: String
    var id: String { name }
}

private struct SetupSkillRow: View {
    @Environment(AppModel.self) private var model
    let skill: DaemonAPI.ListedSkill
    var place: AgentsPlace
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
                    if let error = await model.removeSkill(skill.name, at: place.destination) {
                        failure = CatalogErrorWords.sentence(error)
                    } else {
                        changed()
                    }
                }
            }
        } message: {
            Text(place == .you
                 ? "No agent you start will have it after that. You can take it back out of the Trash."
                 : "Agents in this project won't have it after that. The removal shows in the project's changes, uncommitted.")
        }
    }

    private var detail: String {
        if let managed = skill.managed {
            return [managed.source, managed.commit.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · ")
        }
        return skill.description ?? ""
    }
}

// MARK: - Plugins

struct AgentsPluginsSection: View {
    var place: AgentsPlace

    var body: some View {
        switch place {
        case .project(let folder):
            PluginsSection(folder: folder, showsEmptyState: true)
        case .you:
            YourPluginsSection()
        }
    }
}

/// Plugins in `~/.agents/plugins`. They are yours, so nothing waits for approval.
private struct YourPluginsSection: View {
    @Environment(AppModel.self) private var model
    @State private var folder = ""
    @State private var names: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "Plugins").fixedSize()
                Spacer()
                if !folder.isEmpty {
                    Button("Reveal in Finder") { model.reveal(URL(filePath: folder), on: .mac) }
                        .buttonStyle(.paper)
                        .padding(.top, 20)
                }
            }
            Text("In ~/.agents/plugins. A plugin you put here is yours, and is not asked about.")
                .appText(.fine).foregroundStyle(.secondary)
            if names.isEmpty {
                Text("No plugins yet. A plugin is a folder laid out as Claude’s plugins are.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperRow()
            } else {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Text(name).appText(.reading).fontWeight(.semibold)
                        Spacer()
                        Button("Show in Finder") {
                            model.reveal(URL(filePath: folder).appending(path: name), on: .mac)
                        }
                        .buttonStyle(.paper)
                        .appText(.fine)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .paperRow()
                }
            }
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        guard let snapshot = await model.sharedSnapshot() else { return }
        folder = snapshot.home + "/plugins"
        // This Mac's host lists its own folder: the window reads no disk (058, R12).
        let listing = try? await model.client(for: .mac).call(DaemonAPI.Method.filesBrowse,
                                                              DaemonAPI.FilesBrowseRequest(path: folder),
                                                              returning: DirectoryListing.self)
        names = (listing?.entries ?? []).filter(\.isDirectory).map(\.name)
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
