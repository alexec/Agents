import AgentsKit
import SwiftUI

/// One skill before it goes in (059, look/ frame C, and frame E's left-hand sheet): who
/// wrote it, the commit it is taken at, every file that comes with it, what an agent could
/// run, which runtimes will get it, and its SKILL.md as the agent reads it.
struct SkillPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let preview: DaemonAPI.SkillPreview
    @Binding var addTo: DaemonAPI.SkillDestination
    let projectName: String?
    let runtimes: [DaemonAPI.RuntimeName]
    let back: () -> Void
    let added: (DaemonAPI.ManagedSkill) -> Void
    /// Set when this is an update of a skill already there (US3): what it changes, and
    /// whether the copy there was edited since it was added.
    var update: DaemonAPI.SkillUpdatePreviewAnswer? = nil

    @State private var state: DaemonAPI.DestinationState?
    @State private var adding = false
    @State private var failure: DaemonAPI.CatalogError?
    @State private var confirmingReplace = false
    @State private var askedAgain = false
    @State private var confirmingLoss = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if update == nil {
                    Button("‹ Results", action: back).buttonStyle(.link)
                    Text(preview.name).appText(.title).lineLimit(1)
                    Spacer(minLength: 12)
                    AddToPicker(addTo: $addTo, projectName: projectName, projectFolder: projectFolder)
                } else {
                    Text("Update \(preview.name)").appText(.title).lineLimit(1)
                    Spacer(minLength: 12)
                }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    facts
                    if let update { changes(update.changes) } else { files }
                    if !preview.runnableFiles.isEmpty { scriptWarning }
                    stateNotes
                    HStack(spacing: 8) {
                        ReachDots(runtimes: runtimes, reach: reach)
                        Text(addTo == .personal ? "every agent you start" : "every agent in this project")
                            .appText(.fine).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 300, alignment: .topLeading)
                reader
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity)

            Divider()
            HStack(spacing: 8) {
                Text("Taken from github.com/\(preview.result.source) at \(preview.commit.prefix(7)).")
                    .appText(.fine).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                primaryButton
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Paper.wash)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: addTo) {
            // The preview came with the state for where Add pointed when it was opened;
            // a change of Add to asks again, with nothing fetched a second time.
            if state == nil, !askedAgain {
                state = preview.destinationState
            } else {
                state = await model.catalogDestinationState(preview.previewID, for: addTo)
            }
            askedAgain = true
            failure = nil
        }
        .confirmationDialog("Your edits to \(preview.name) will be lost", isPresented: $confirmingLoss) {
            Button("Update anyway", role: .destructive) { Task { await add(replace: true) } }
        } message: {
            Text("The copy there was changed since it was added. Updating puts it in the Trash and takes the new one.")
        }
        .confirmationDialog("Replace \(preview.name)?", isPresented: $confirmingReplace) {
            Button("Replace") { Task { await add(replace: true) } }
        } message: {
            Text("The copy there now goes to the Trash.")
        }
    }

    // MARK: The left column

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            SharedFact(label: "Owner", value: preview.result.owner)
            SharedFact(label: "Repo", value: preview.result.repo)
            SharedFact(label: "Commit", value: commitLine, code: true)
            // An update comes from the lock, not a search, so there is no count to show.
            if update == nil {
                SharedFact(label: "Installs", value: "\(AddSkillSheet.count(preview.result.installs)) on skills.sh")
            }
            SharedFact(label: "Goes to", value: goesTo, code: true)
        }
    }

    private var files: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(preview.files, id: \.path) { file in
                    HStack(spacing: 6) {
                        Text(file.path).appText(.code).lineLimit(1).truncationMode(.middle)
                        if file.runnable { SharedChip(text: "script", tone: .attention) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        // Tall enough for every file of a small skill, then it scrolls.
        .frame(height: min(CGFloat(preview.files.count) * 19 + 22, 150))
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Paper.rule, lineWidth: 1))
        .accessibilityLabel("\(preview.files.count) files")
    }

    /// What an update changes, file by file, in place of the plain file list.
    private func changes(_ changes: DaemonAPI.SkillChanges) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("What changes").appText(.fine).foregroundStyle(.secondary)
            if changes.added.isEmpty && changes.changed.isEmpty && changes.removed.isEmpty {
                Text("Nothing in the files; only the commit moves on.").appText(.supporting)
            }
            ForEach(changes.changed, id: \.self) { changeRow("changed", $0) }
            ForEach(changes.added, id: \.self) { changeRow("new", $0) }
            ForEach(changes.removed, id: \.self) { changeRow("gone", $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Paper.rule, lineWidth: 1))
    }

    private func changeRow(_ kind: String, _ path: String) -> some View {
        HStack(spacing: 6) {
            SharedChip(text: kind, tone: kind == "gone" ? .attention : .source)
            Text(path).appText(.code).lineLimit(1).truncationMode(.middle)
        }
    }

    private var scriptWarning: some View {
        let n = preview.runnableFiles.count
        return Text(n == 1 ? "This skill brings a script. An agent may run it when the skill is in use, with the same permissions as the agent."
                           : "This skill brings \(n) scripts. An agent may run them when the skill is in use, with the same permissions as the agent.")
            .appText(.supporting)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SharedInk.attention.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Frame E's notes: what is there already, and anything the preview found.
    @ViewBuilder
    private var stateNotes: some View {
        if let failure {
            note(CatalogErrorWords.sentence(failure), attention: true)
        }
        if update?.edited == true {
            note("You've edited this skill since it was added. Updating replaces your edits; the copy with them goes to the Trash.",
                 attention: true)
        }
        if !preview.canAdd {
            note(problemWords, attention: true)
        }
        switch state {
        case .unmanaged(let path)?:
            note("You already have a skill called \(preview.name) in \(Self.tilde(URL(filePath: path).deletingLastPathComponent().path)). You made it (it didn't come from here), so the app won't replace it.",
                 attention: true)
        case .managedOther(let source)?:
            note("A skill of this name from \(source) is there already. Adding this one replaces it.", attention: false)
        case .sameSkill(let update)? where self.update == nil:
            note(update ? "An older copy of this skill is there. Adding replaces it with this commit." : "This skill is added already.",
                 attention: false)
        case .unavailable(let error)?:
            note(CatalogErrorWords.sentence(error), attention: true)
        case .free?, .sameSkill?, nil:
            EmptyView()
        }
    }

    private func note(_ text: String, attention: Bool) -> some View {
        Text(text)
            .appText(.supporting)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((attention ? SharedInk.attention : SharedInk.reach).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: The reader

    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("SKILL.md").appText(.code).foregroundStyle(.secondary)
                Text(preview.name).appText(.reading).fontWeight(.semibold)
                if !preview.description.isEmpty { Text(preview.description).appText(.supporting) }
                Text(Self.body(of: preview.skillMarkdown)).appText(.supporting).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule, lineWidth: 1))
    }

    // MARK: Add

    @ViewBuilder
    private var primaryButton: some View {
        if update != nil {
            Button("Update") {
                if update?.edited == true { confirmingLoss = true } else { Task { await add(replace: true) } }
            }
            .buttonStyle(.paperProminent)
            .disabled(adding || !preview.canAdd)
            .keyboardShortcut(.defaultAction)
        } else {
            addButton
        }
    }

    @ViewBuilder
    private var addButton: some View {
        switch state {
        case .unmanaged(let path)?:
            Button("Reveal yours") { SharedFiles.reveal(path) }.buttonStyle(.paper)
        case .sameSkill(false)?:
            Button("Added") {}.buttonStyle(.paper).disabled(true)
        case .managedOther?, .sameSkill(true)?:
            Button("Replace in \(placeName)") { confirmingReplace = true }
                .buttonStyle(.paperProminent).disabled(adding || !preview.canAdd)
        default:
            Button("Add to \(placeName)") { Task { await add(replace: false) } }
                .buttonStyle(.paperProminent)
                .disabled(adding || !preview.canAdd || state == nil)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func add(replace: Bool) async {
        adding = true
        defer { adding = false }
        switch await model.addSkill(preview.previewID, to: addTo, replace: replace) {
        case .success(let skill): added(skill)
        case .failure(let error): failure = error
        }
    }

    // MARK: Words

    private var projectFolder: String? {
        if case .project(let folder) = addTo { return folder }
        guard let key = model.selectedProjectKey, key.host == .mac else {
            return model.liveProjects.first { $0.host == .mac }?.project.folder.path
        }
        return key.folder.path
    }

    private var placeName: String { addTo == .personal ? "~/.agents" : (projectName ?? "the project") }

    private var goesTo: String {
        switch addTo {
        case .personal: "~/.agents/skills/\(preview.name)"
        case .project(let folder): Self.tilde(folder) + "/.agents/skills/\(preview.name)"
        }
    }

    private var commitLine: String {
        let short = String(preview.commit.prefix(7))
        guard let at = preview.committedAt else { return short }
        return "\(short) · \(at.formatted(.relative(presentation: .named)))"
    }

    private var problemWords: String {
        for problem in preview.problems where problem.blocksAdding {
            switch problem {
            case .noSkillFile: return "Its SKILL.md has no name or description, so no agent would pick it up."
            case .notFoundInRepo: return "The skill isn't where the catalogue says it is in that repository."
            case .tooLarge(let bytes, let files):
                return "It's too large to add: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) in \(files) files."
            case .skipped: continue
            }
        }
        return "This skill can't be added."
    }

    /// Every runtime gets a skill in `~/.agents/skills` or a project's `.agents/skills` (054).
    private var reach: [String: DaemonAPI.Reach] {
        Dictionary(uniqueKeysWithValues: runtimes.map { ($0.id, DaemonAPI.Reach.gets("")) })
    }

    static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// The file without its front matter, which the lines above already show.
    static func body(of text: String) -> String {
        guard text.hasPrefix("---"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
        else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
