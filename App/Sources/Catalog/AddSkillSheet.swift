import AgentsKitCore
import SwiftUI

/// Add a skill (059, look/ frames B, C and E): search a marketplace (skills.sh unless the
/// person chose another, #687), look at one skill as its agent will read it, and add it
/// where the sheet was opened (#688): Settings adds to the person's `~/.agents`, Folder
/// Settings to that folder's `.agents`.
///
/// Nothing is added from the list. Choosing a row fetches that skill at its repository's
/// current commit and shows every file; Add then puts exactly those files in place.
struct AddSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Where Add puts a skill. There is no choosing another place here.
    let destination: DaemonAPI.SkillDestination
    /// The runtimes the reach dots are drawn for.
    let runtimes: [DaemonAPI.RuntimeName]
    /// The skills a catalogue already added where Add points, for the **added** marks. A
    /// same-named skill of the person's own is not this one, so it is not marked.
    var installed: Set<String> = []
    /// Called after a skill was added, so the page behind can read itself again.
    var onAdded: () -> Void = {}

    @State private var query = ""
    @State private var results: [DaemonAPI.CatalogResult] = []
    @State private var searched = false
    @State private var searchError: DaemonAPI.CatalogError?
    /// Names already where Add points, for the **added** marks.
    @State private var added: Set<String> = []
    @State private var opening: DaemonAPI.CatalogResult?
    @State private var preview: DaemonAPI.SkillPreview?
    @State private var previewError: DaemonAPI.CatalogError?
    /// The result whose preview was refused, for Ask an Admin (#2355).
    @State private var refused: DaemonAPI.CatalogResult?
    @State private var marketplaces: [DaemonAPI.Marketplace] = []
    @State private var managing = false
    /// The marketplace last searched, kept across sheets (#687).
    @AppStorage("catalog.skills.marketplace", store: WindowDefaults.store) private var chosen = "provided:skills-sh"

    static let size = CGSize(width: 720, height: 540)

    var body: some View {
        VStack(spacing: 0) {
            if managing {
                MarketplacesPane(kind: .skills, destination: destination, back: {
                    managing = false
                    Task { await loadMarketplaces() }
                })
            } else if let preview {
                SkillPreviewView(preview: preview, addTo: destination, folderName: folderName, runtimes: runtimes,
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
        .onAppear { added = installed }
    }

    // MARK: Frame B

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Add a skill").appText(.title)
                Spacer()
                MarketplaceMenu(marketplaces: marketplaces, chosen: $chosen, manage: { managing = true })
                Text(folderName.map { "Adds to \($0)" } ?? "Adds to ~/.agents").appText(.fine).foregroundStyle(.secondary)
            }
            TextField("Search \(marketplace?.name ?? "skills")", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search skills")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if marketplace == nil && !marketplaces.isEmpty {
                        Text("Every skills marketplace is off. Manage Marketplaces… in the menu turns one on.")
                            .appText(.fine).foregroundStyle(.secondary).padding(.top, 8)
                    } else if let searchError {
                        CatalogProblemView(error: searchError, retry: { Task { await search(query) } })
                    } else if let previewError {
                        CatalogProblemView(error: previewError, retry: nil, refused: refused)
                    } else if results.isEmpty && searched {
                        Text("No skills match.").appText(.fine).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    ForEach(results) { result in resultRow(result) }
                }
            }
            HStack {
                Text("From \(marketplace?.host ?? "no marketplace"). Choose one to see what is in it before adding.")
                    .appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .task { await loadMarketplaces() }
        .task(id: SearchKey(query: query, marketplace: marketplace?.id)) {
            // A pause after the last keystroke before asking (research R1).
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private func resultRow(_ result: DaemonAPI.CatalogResult) -> some View {
        SharedRow(chosen: opening?.id == result.id,
                  label: "\(result.name), \(result.source)" + (result.installs > 0 ? ", \(result.installs) installs" : "")
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
                } else if result.installs > 0 {
                    Text("\(Self.count(result.installs)) installs").appText(.fine).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Asking the daemon

    private func search(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let marketplace else {
            results = []; searched = false; searchError = nil
            return
        }
        // A repository is small enough to list whole before anything is typed.
        let browses = marketplace.format == .gitHubSkills
        guard trimmed.count >= 2 || (browses && trimmed.isEmpty) else {
            results = []
            searched = false
            searchError = nil
            return
        }
        let answer = await model.catalogSearch(trimmed, marketplace: marketplace.id, destination: destination)
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
        let answer = await model.catalogPreview(result, for: destination)
        opening = nil
        if let fresh = answer.preview {
            preview = fresh
            refused = nil
        } else {
            previewError = answer.error ?? .failed("no answer")
            refused = result
        }
    }

    private var marketplace: DaemonAPI.Marketplace? {
        MarketplaceMenu(marketplaces: marketplaces, chosen: .constant(chosen), manage: {}).current
    }

    private func loadMarketplaces() async {
        if let answer = await model.marketplaces(.skills, for: destination) { marketplaces = answer.marketplaces }
    }

    // MARK: Words

    /// The folder's name when the sheet adds to a folder.
    private var folderName: String? {
        guard case .folder(let folder) = destination else { return nil }
        return model.liveFolders.first { $0.folder.folder.path == folder }?.name ?? URL(filePath: folder).lastPathComponent
    }

    /// 32978 → "33k", 9188 → "9.2k", 951 → "951", as frame B has them.
    static func count(_ n: Int) -> String {
        if n >= 10_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// Frame E's right-hand sheet, and the other reasons a search or a preview came back empty.
struct CatalogProblemView: View {
    let error: DaemonAPI.CatalogError
    let retry: (() -> Void)?
    /// The skill whose preview the organisation's policy refused: Ask an Admin for it (#2355).
    var refused: DaemonAPI.CatalogResult?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).appText(.reading).fontWeight(.semibold)
            Text(detail).appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry { Button("Try again", action: retry).buttonStyle(.paper) }
            if error.policyWords != nil, let refused {
                AskAdminButton(kind: .skills, name: refused.name, source: refused.source)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 40)
    }

    private var title: String {
        switch error {
        case .unreachable(let host): "Can't reach \(host)"
        case .rateLimited: "GitHub is limiting requests"
        case _ where error.policyWords != nil: "Your organisation does not allow this skill"
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
        // The organisation's policy says its own words, whole (#2355).
        if let words = error.policyWords { return words }
        return switch error {
        case .unreachable(let host): "Can't reach \(host)."
        case .rateLimited: "GitHub is limiting requests. Try again in a few minutes."
        case .unmanaged(let path): "You already have a skill at \((path as NSString).abbreviatingWithTildeInPath). You made it, so the app won't replace it."
        case .lockUnreadable(let path): "\((path as NSString).abbreviatingWithTildeInPath) could not be read, so nothing was changed."
        case .noPersonalHome: "This copy of the app has no ~/.agents of its own."
        case .previewExpired: "That preview has expired. Open the skill again."
        case .notAFolder(let path): "\((path as NSString).abbreviatingWithTildeInPath) is not a folder on this Mac."
        case .replaceMismatch: "The skill there has changed since this was opened. Open it again."
        case .cannotAdd: "This skill can't be added."
        case .notManaged(let name): "\(name) wasn't added by the app or the skills tool."
        case .failed(let why): "It couldn't be added: \(why)"
        }
    }
}
