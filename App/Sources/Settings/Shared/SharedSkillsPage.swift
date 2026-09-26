import AgentsKit
import SwiftUI

/// Frame B: every skill an agent will be offered, the person's then those a plugin
/// brings, and one in detail with its `SKILL.md` as the agent reads it.
struct SharedSkillsPage: View {
    let snapshot: DaemonAPI.SharedSnapshot
    @State private var filter = ""
    @State private var chosenID: String?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Filter skills", text: $filter)
                        .textFieldStyle(.roundedBorder)
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
                SkillDetail(skill: chosen, runtimes: snapshot.runtimes)
                    .id(chosen.id)
            } else {
                Text("Choose a skill").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
                  label: "\(skill.name)\(skill.clash != nil ? ", clash" : ""). \(ReachDots.spoken(snapshot.runtimes, skill.reach))",
                  action: { chosenID = skill.id }) {
            HStack(spacing: 8) {
                Text(skill.name).fontWeight(.semibold).lineLimit(1).fixedSize()
                if skill.clash != nil { SharedChip(text: "clash", tone: .attention) }
                if case .plugin(let plugin) = skill.source { SharedChip(text: plugin, tone: .source) }
                Text(skill.clash.map { "Also in \(SharedFiles.tilde($0))" } ?? skill.description ?? "")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                ReachDots(runtimes: snapshot.runtimes, reach: skill.reach)
            }
        }
    }
}

private struct SkillDetail: View {
    let skill: DaemonAPI.Skill
    let runtimes: [DaemonAPI.RuntimeName]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(skill.name).appText(.reading).fontWeight(.semibold)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                SharedFact(label: "Folder", value: SharedFiles.tilde(skill.path), code: true)
                if case .plugin(let plugin) = skill.source { SharedFact(label: "Plugin", value: plugin) }
                if let clash = skill.clash { SharedFact(label: "Also in", value: SharedFiles.tilde(clash), code: true) }
            }
            SharedReachList(runtimes: runtimes, reach: skill.reach)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SKILL.md").appText(.code).foregroundStyle(.secondary)
                    Text(text).appText(.supporting).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule, lineWidth: 1))
            HStack {
                Button("Reveal in Finder") { SharedFiles.reveal(skill.path) }.buttonStyle(.paper)
                Button("Edit SKILL.md") { SharedFiles.open(skill.path + "/SKILL.md") }.buttonStyle(.paper)
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
