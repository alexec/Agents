import AgentsKit
import SwiftUI

/// Add a skill (059, look/ frames B, C and E): search skills.sh, look at one skill as its
/// agent will read it, and add it to the person's `~/.agents` or to a project.
///
/// Nothing is added from the list. Choosing a row fetches that skill at its repository's
/// current commit and shows every file; Add then puts exactly those files in place.
struct AddSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Where Add points when the sheet opens.
    let destination: DaemonAPI.SkillDestination
    /// The runtimes the reach dots are drawn for.
    let runtimes: [DaemonAPI.RuntimeName]
    /// The skills already where Add points when the sheet opens, for the **added** marks.
    var installed: Set<String> = []
    /// Called after a skill was added, so the page behind can read itself again.
    var onAdded: () -> Void = {}

    @State private var addTo: DaemonAPI.SkillDestination = .personal
    @State private var query = ""
    @State private var results: [DaemonAPI.CatalogResult] = []
    @State private var searched = false
    @State private var searchError: DaemonAPI.CatalogError?
    /// Names already where Add points, for the **added** marks.
    @State private var added: Set<String> = []
    @State private var opening: DaemonAPI.CatalogResult?
    @State private var preview: DaemonAPI.SkillPreview?
    @State private var previewError: DaemonAPI.CatalogError?

    static let size = CGSize(width: 720, height: 540)

    var body: some View {
        VStack(spacing: 0) {
            if let preview {
                SkillPreviewView(preview: preview, addTo: $addTo, projectName: projectName, runtimes: runtimes,
                                 back: { self.preview = nil },
                                 added: { skill in
                                     self.added.insert(skill.name)
                                     self.preview = nil
                                     onAdded()
                                 })
            } else {
                searchPane
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Paper.ground)
        .onAppear {
            addTo = destination
            added = installed
        }
        // The **added** marks follow Add to, with no new search (US2 #5).
        .task(id: addTo) {
            guard addTo != destination || added.isEmpty else { return }
            switch addTo {
            case .personal:
                if let snapshot = await model.sharedSnapshot() {
                    added = Set(snapshot.skills.filter { $0.source == .personal }.map(\.name))
                }
            case .project(let folder):
                if let listed = await model.projectSkills(URL(filePath: folder)) { added = Set(listed.map(\.name)) }
            }
        }
    }

    // MARK: Frame B

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Add a skill").appText(.title)
                Spacer()
                AddToPicker(addTo: $addTo, projectName: projectName, projectFolder: projectFolder)
            }
            TextField("Search skills", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search skills")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let searchError {
                        CatalogProblemView(error: searchError, retry: { Task { await search(query) } })
                    } else if let previewError {
                        CatalogProblemView(error: previewError, retry: nil)
                    } else if results.isEmpty && searched {
                        Text("No skills match.").appText(.fine).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(results) { result in resultRow(result) }
                }
            }
            HStack {
                Text("From skills.sh. Choose one to see what is in it before adding.")
                    .appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .task(id: query) {
            // A pause after the last keystroke before asking (research R1).
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private func resultRow(_ result: DaemonAPI.CatalogResult) -> some View {
        SharedRow(chosen: opening?.id == result.id,
                  label: "\(result.name), \(result.source), \(result.installs) installs"
                      + (result.known ? ", known owner" : "") + (added.contains(result.skillID) ? ", added" : ""),
                  action: { Task { await open(result) } }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.name).fontWeight(.semibold).lineLimit(1)
                        if result.known { SharedChip(text: "known", tone: .source) }
                        if added.contains(result.skillID) { SharedChip(text: "added") }
                    }
                    Text(result.source).appText(.code).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if opening?.id == result.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(Self.count(result.installs)) installs").appText(.fine).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Asking the daemon

    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            searched = false
            searchError = nil
            return
        }
        let answer = await model.catalogSearch(trimmed)
        guard text == query else { return }
        results = answer.results
        searchError = answer.error
        previewError = nil
        searched = true
    }

    private func open(_ result: DaemonAPI.CatalogResult) async {
        guard opening == nil else { return }
        opening = result
        previewError = nil
        let answer = await model.catalogPreview(result, for: addTo)
        opening = nil
        if let fresh = answer.preview {
            preview = fresh
        } else {
            previewError = answer.error ?? .failed("no answer")
        }
    }

    // MARK: Words

    private var projectFolder: String? {
        if case .project(let folder) = destination { return folder }
        if let key = model.selectedProjectKey, key.host == .mac { return key.folder.path }
        return model.liveProjects.first { $0.host == .mac }?.project.folder.path
    }

    private var projectName: String? {
        guard let folder = projectFolder else { return nil }
        return model.liveProjects.first { $0.project.folder.path == folder }?.name ?? URL(filePath: folder).lastPathComponent
    }

    /// 32978 → "33k", 9188 → "9.2k", 951 → "951", as frame B has them.
    static func count(_ n: Int) -> String {
        if n >= 10_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// Add to: the person, or the project the sheet belongs to.
struct AddToPicker: View {
    @Binding var addTo: DaemonAPI.SkillDestination
    let projectName: String?
    let projectFolder: String?

    var body: some View {
        HStack(spacing: 8) {
            Text("Add to").foregroundStyle(.secondary).fixedSize()
            Picker("Add to", selection: $addTo) {
                Text("You").tag(DaemonAPI.SkillDestination.personal)
                if let projectFolder, let projectName {
                    Text("\(projectName) (project)").tag(DaemonAPI.SkillDestination.project(folder: projectFolder))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Frame E's right-hand sheet, and the other reasons a search or a preview came back empty.
struct CatalogProblemView: View {
    let error: DaemonAPI.CatalogError
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).appText(.reading).fontWeight(.semibold)
            Text(detail).appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry { Button("Try again", action: retry).buttonStyle(.paper) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 40)
    }

    private var title: String {
        switch error {
        case .unreachable(let host): "Can't reach \(host)"
        case .rateLimited: "GitHub is limiting requests"
        default: "This skill can't be shown"
        }
    }

    private var detail: String {
        switch error {
        case .unreachable(let host):
            "The Mac looks to be offline, or \(host) isn't answering. The skills you have are unaffected."
        case .rateLimited:
            "Try again in a few minutes. Signing in to GitHub with gh raises the limit."
        default:
            CatalogErrorWords.sentence(error)
        }
    }
}

/// A catalogue refusal in the window's words.
enum CatalogErrorWords {
    static func sentence(_ error: DaemonAPI.CatalogError) -> String {
        switch error {
        case .unreachable(let host): "Can't reach \(host)."
        case .rateLimited: "GitHub is limiting requests. Try again in a few minutes."
        case .unmanaged(let path): "You already have a skill at \((path as NSString).abbreviatingWithTildeInPath). You made it, so the app won't replace it."
        case .lockUnreadable(let path): "\((path as NSString).abbreviatingWithTildeInPath) could not be read, so nothing was changed."
        case .noPersonalHome: "This copy of the app has no ~/.agents of its own."
        case .previewExpired: "That preview has expired. Open the skill again."
        case .notAProject(let path): "\((path as NSString).abbreviatingWithTildeInPath) is not a project on this Mac."
        case .replaceMismatch: "The skill there has changed since this was opened. Open it again."
        case .cannotAdd: "This skill can't be added."
        case .notManaged(let name): "\(name) wasn't added by the app or the skills tool."
        case .failed(let why): "It couldn't be added: \(why)"
        }
    }
}
