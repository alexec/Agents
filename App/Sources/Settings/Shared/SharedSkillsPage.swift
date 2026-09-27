import AgentsKit
import SwiftUI

/// Frame B: every skill an agent will be offered, the person's then those a plugin
/// brings, and one in detail with its `SKILL.md` as the agent reads it.
struct SharedSkillsPage: View {
    let snapshot: DaemonAPI.SharedSnapshot
    /// Read the snapshot again, after a skill was added (059).
    var refresh: () async -> Void = {}
    @State private var filter = ""
    @State private var chosenID: String?
    @State private var adding = false
    /// Which added skills have an update, asked for when the page appears (FR-018).
    @State private var updates: [String: DaemonAPI.UpdateState] = [:]
    @State private var updating: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Filter skills", text: $filter)
                            .textFieldStyle(.roundedBorder)
                        // 059, frame A: search a catalogue and add to ~/.agents.
                        Button("Add skill…") { adding = true }.buttonStyle(.paperProminent)
                    }
                    if !yours.isEmpty {
                        SharedSectionLabel("Yours · ~/.agents/skills")
                        ForEach(yours) { row($0) }
                    }
                    if !fromPlugins.isEmpty {
                        SharedSectionLabel("From plugins")
                        ForEach(fromPlugins) { row($0) }
                    }
                    if yours.isEmpty && fromPlugins.isEmpty {
                        Text(filter.isEmpty ? "No skills yet. A folder in ~/.agents/skills with a SKILL.md in it is one."
                                            : "No skill matches.")
                            .appText(.fine).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .frame(width: 400)
            Divider()
            if let chosen {
                SkillDetail(skill: chosen, runtimes: snapshot.runtimes,
                            hasUpdate: Self.available(updates[chosen.name]),
                            update: { updating = chosen.name },
                            removed: { Task { await refresh() } })
                    .id("\(chosen.id)@\(chosen.managed?.commit ?? "")")
            } else {
                Text("Choose a skill").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if let fresh = await model.skillUpdates(at: .personal) { updates = fresh } }
        .sheet(item: Binding(get: { updating.map(UpdateTarget.init) }, set: { updating = $0?.name })) { target in
            UpdateSkillSheet(name: target.name, destination: .personal, runtimes: snapshot.runtimes,
                             onUpdated: { Task {
                                 await refresh()
                                 if let fresh = await model.skillUpdates(at: .personal) { updates = fresh }
                             } })
        }
        .sheet(isPresented: $adding) {
            AddSkillSheet(destination: .personal, runtimes: snapshot.runtimes,
                          installed: Set(yours.filter { $0.managed != nil }.map(\.name)),
                          onAdded: { Task { await refresh() } })
        }
    }

    static func available(_ state: DaemonAPI.UpdateState?) -> Bool {
        if case .available? = state { return true }
        return false
    }

    private var matching: [DaemonAPI.Skill] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return snapshot.skills }
        return snapshot.skills.filter {
            $0.name.lowercased().contains(needle) || ($0.description?.lowercased().contains(needle) ?? false)
        }
    }

    private var yours: [DaemonAPI.Skill] { matching.filter { $0.source == .personal } }
    private var fromPlugins: [DaemonAPI.Skill] { matching.filter { $0.source != .personal } }

    private var chosen: DaemonAPI.Skill? {
        snapshot.skills.first { $0.id == chosenID } ?? matching.first
    }

    private func row(_ skill: DaemonAPI.Skill) -> some View {
        SharedRow(chosen: skill.id == chosen?.id,
                  label: "\(skill.name)\(skill.clash != nil ? ", clash" : "")\(Self.available(updates[skill.name]) ? ", update available" : ""). \(ReachDots.spoken(snapshot.runtimes, skill.reach))",
                  action: { chosenID = skill.id }) {
            HStack(spacing: 8) {
                Text(skill.name).fontWeight(.semibold).lineLimit(1).fixedSize()
                if skill.clash != nil { SharedChip(text: "clash", tone: .attention) }
                if case .plugin(let plugin) = skill.source { SharedChip(text: plugin, tone: .source) }
                if skill.managed != nil { SharedChip(text: "skills.sh", tone: .source) }
                if Self.available(updates[skill.name]) { SharedChip(text: "update", tone: .attention) }
                Text(skill.clash.map { "Also in \(SharedFiles.tilde($0))" } ?? skill.description ?? "")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                ReachDots(runtimes: snapshot.runtimes, reach: skill.reach)
            }
        }
    }
}

private struct SkillDetail: View {
    /// The file without its front matter, which the lines above already show.
    static func body(of text: String) -> String {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let skill: DaemonAPI.Skill
    let runtimes: [DaemonAPI.RuntimeName]
    var hasUpdate = false
    var update: () -> Void = {}
    var removed: () -> Void = {}
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var confirmingRemove = false
    @State private var removeFailure: String?

    static func takenAt(_ managed: DaemonAPI.ManagedSkill) -> String {
        guard let commit = managed.commit else { return "not recorded" }
        let short = String(commit.prefix(7))
        guard let at = managed.committedAt else { return short }
        return "\(short) · \(at.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(skill.name).appText(.reading).fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                SharedFact(label: "Folder", value: SharedFiles.tilde(skill.path), code: true)
                if case .plugin(let plugin) = skill.source { SharedFact(label: "Plugin", value: plugin) }
                if let clash = skill.clash { SharedFact(label: "Also in", value: SharedFiles.tilde(clash), code: true) }
                // 059: where a lock says it came from, and the commit it was taken at.
                if let managed = skill.managed {
                    SharedFact(label: "From", value: "skills.sh · \(managed.source)")
                    SharedFact(label: "Taken at", value: Self.takenAt(managed), code: managed.commit != nil)
                }
            }
            SharedReachList(runtimes: runtimes, reach: skill.reach)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SKILL.md").appText(.code).foregroundStyle(.secondary)
                    // As the agent is offered it: its name and description, then the body.
                    Text(skill.name).appText(.reading).fontWeight(.semibold)
                    if let description = skill.description {
                        Text(description).appText(.supporting)
                    }
                    Text(Self.body(of: text)).appText(.supporting).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .paperRaised(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
            if let removeFailure {
                Text(removeFailure).appText(.fine).foregroundStyle(SharedInk.attention)
            }
            // Only for a skill a lock names: the person's own keep exactly today's actions (FR-021).
            // A row of its own, so four buttons never squeeze the detail wider than the window.
            if skill.managed != nil {
                HStack {
                    if hasUpdate { Button("Update…", action: update).buttonStyle(.paperProminent) }
                    Button("Remove…") { confirmingRemove = true }.buttonStyle(.paper)
                }
            }
            HStack {
                Button("Reveal in Finder") { SharedFiles.reveal(skill.path) }.buttonStyle(.paper)
                Button("Edit SKILL.md") { SharedFiles.open(skill.path + "/SKILL.md") }.buttonStyle(.paper)
            }
            .confirmationDialog("Move \(skill.name) to the Trash?", isPresented: $confirmingRemove) {
                Button("Move to Trash", role: .destructive) {
                    Task {
                        if let error = await model.removeSkill(skill.name, at: .personal) {
                            removeFailure = CatalogErrorWords.sentence(error)
                        } else {
                            removed()
                        }
                    }
                }
            } message: {
                Text("No agent you start will have it after that. You can take it back out of the Trash.")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            text = (try? String(contentsOf: URL(filePath: skill.path).appending(path: "SKILL.md"), encoding: .utf8))
                ?? "No SKILL.md in this folder."
        }
    }
}

/// A skill to update, as a sheet's item.
struct UpdateTarget: Identifiable {
    let name: String
    var id: String { name }
}
