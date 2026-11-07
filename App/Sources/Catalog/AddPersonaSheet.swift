import AgentsKitCore
import SwiftUI

/// Personas from a marketplace (#3665): a GitHub marketplace's `personas/<id>.md`, added
/// where the page was opened, as a skill is. The page lists the ones added this way, each
/// with **update** when its source moved on, **Update…** and **Remove…**. A persona the
/// person made is in the editor below, and this never touches it.
struct MarketplacePersonasSection: View {
    @Environment(AppModel.self) private var model
    let place: AgentsPlace
    /// Called after a persona was added, updated or removed, so the editor reads its files again.
    var changed: () -> Void = {}

    @State private var personas: [DaemonAPI.ManagedPersona] = []
    @State private var updates: [String: DaemonAPI.UpdateState] = [:]
    @State private var adding = false
    @State private var updating: String?
    @State private var removing: DaemonAPI.ManagedPersona?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !personas.isEmpty { SharedSectionLabel("From a marketplace") }
                Spacer()
                Button("Add persona…") { adding = true }.buttonStyle(.paper)
            }
            ForEach(personas) { persona in row(persona) }
            if let failure { Text(failure).appText(.fine).foregroundStyle(SharedInk.attention) }
        }
        .task(id: place) { await load() }
        .sheet(isPresented: $adding) {
            AddPersonaSheet(destination: place.destination, installed: Set(personas.map(\.id)),
                            onAdded: { Task { await reload() } })
        }
        .sheet(item: Binding(get: { updating.map(UpdateTarget.init) }, set: { updating = $0?.name })) { target in
            UpdatePersonaSheet(id: target.name, destination: place.destination, onUpdated: { Task { await reload() } })
        }
        .confirmationDialog("Move \(removing?.id ?? "persona").md to the Trash?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Move to Trash", role: .destructive) {
                guard let persona = removing else { return }
                Task {
                    if let error = await model.removePersona(persona.id, at: place.destination) {
                        failure = CatalogErrorWords.sentence(error)
                    } else {
                        failure = nil
                        await reload()
                    }
                }
            }
        } message: {
            Text(place == .you
                 ? "New sessions can't pick it after that. You can take it back out of the Trash."
                 : "New sessions in this folder can't pick it after that. The removal shows in the folder's changes, uncommitted.")
        }
    }

    private func row(_ persona: DaemonAPI.ManagedPersona) -> some View {
        let hasUpdate = if case .available? = updates[persona.id] { true } else { false }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(persona.id).appText(.reading).fontWeight(.semibold).lineLimit(1).fixedSize()
            if hasUpdate { SharedChip(text: "update", tone: .attention) }
            if persona.edited { SharedChip(text: "edited") }
            Text([persona.source, persona.commit.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · "))
                .appText(.supporting).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if hasUpdate {
                Button("Update…") { updating = persona.id }.buttonStyle(.paperProminent).appText(.fine)
            }
            Button("Remove…") { removing = persona }.buttonStyle(.paper).appText(.fine)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRow()
        .accessibilityElement(children: .contain)
    }

    private func reload() async {
        await load()
        changed()
    }

    private func load() async {
        if let fresh = await model.managedPersonas(at: place.destination) { personas = fresh }
        if !personas.isEmpty, let fresh = await model.personaUpdates(at: place.destination) { updates = fresh }
    }
}

/// Add a persona: choose a GitHub marketplace, search its `personas/` folder, and look at the
/// whole file before it goes in.
struct AddPersonaSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let destination: DaemonAPI.SkillDestination
    /// The personas already added from a marketplace here, for the **added** marks.
    var installed: Set<String> = []
    var onAdded: () -> Void = {}

    @State private var query = ""
    @State private var results: [DaemonAPI.CatalogResult] = []
    @State private var searched = false
    @State private var searchError: DaemonAPI.CatalogError?
    @State private var added: Set<String> = []
    @State private var opening: DaemonAPI.CatalogResult?
    @State private var preview: DaemonAPI.PersonaPreview?
    @State private var previewError: DaemonAPI.CatalogError?
    @State private var marketplaces: [DaemonAPI.Marketplace] = []
    @State private var managing = false
    /// The marketplace last searched for personas, kept across sheets.
    @AppStorage("catalog.personas.marketplace", store: WindowDefaults.store) private var chosen = "provided:anthropic-skills"

    var body: some View {
        VStack(spacing: 0) {
            if managing {
                MarketplacesPane(kind: .skills, destination: destination, back: {
                    managing = false
                    Task { await loadMarketplaces() }
                })
            } else if let preview {
                PersonaPreviewView(preview: preview, addTo: destination, back: { self.preview = nil },
                                   added: { persona in
                                       added.insert(persona.id)
                                       self.preview = nil
                                       onAdded()
                                   })
            } else {
                searchPane
            }
        }
        .frame(width: AddSkillSheet.size.width, height: AddSkillSheet.size.height)
        .background(Paper.ground)
        .onAppear { added = installed }
    }

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Add a persona").appText(.title)
                Spacer()
                MarketplaceMenu(marketplaces: marketplaces, chosen: $chosen, manage: { managing = true })
                Text(destination == .personal ? "Adds to ~/.agents" : "Adds to this folder")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            TextField("Search \(marketplace?.name ?? "personas")", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search personas")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if marketplace == nil && !marketplaces.isEmpty {
                        Text("No GitHub marketplace is on. Manage Marketplaces… in the menu adds or turns one on.")
                            .appText(.fine).foregroundStyle(.secondary).padding(.top, 8)
                    } else if let searchError {
                        CatalogProblemView(error: searchError, retry: { Task { await search(query) } })
                    } else if let previewError {
                        CatalogProblemView(error: previewError, retry: nil)
                    } else if results.isEmpty && searched {
                        Text("No personas in its personas/ folder match.").appText(.fine).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(results) { result in resultRow(result) }
                }
            }
            HStack {
                Text("Personas are personas/<id>.md in a GitHub marketplace's repository. Choose one to read it before adding.")
                    .appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .task { await loadMarketplaces() }
        .task(id: SearchKey(query: query, marketplace: marketplace?.id)) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private func resultRow(_ result: DaemonAPI.CatalogResult) -> some View {
        SharedRow(chosen: opening?.id == result.id,
                  label: "\(result.name), \(result.source)" + (added.contains(result.skillID) ? ", added" : ""),
                  action: { Task { await open(result) } }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.name).fontWeight(.semibold).lineLimit(1)
                        if result.known { SharedChip(text: "known", tone: .source) }
                        if added.contains(result.skillID) { SharedChip(text: "added") }
                    }
                    Text(result.skillPath ?? result.source).appText(.code).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if opening?.id == result.id { ProgressView().controlSize(.small) }
            }
        }
    }

    /// Only a GitHub repository holds persona files; skills.sh lists skills alone.
    private var personaMarketplaces: [DaemonAPI.Marketplace] { marketplaces.filter { $0.format == .gitHubSkills } }

    private var marketplace: DaemonAPI.Marketplace? {
        MarketplaceMenu(marketplaces: personaMarketplaces, chosen: .constant(chosen), manage: {}).current
    }

    private func search(_ text: String) async {
        guard let marketplace else {
            results = []; searched = false; searchError = nil
            return
        }
        let answer = await model.personaSearch(text.trimmingCharacters(in: .whitespaces), marketplace: marketplace.id,
                                               destination: destination)
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
        let answer = await model.personaPreview(result, for: destination)
        opening = nil
        if let fresh = answer.preview { preview = fresh } else { previewError = answer.error ?? .failed("no answer") }
    }

    private func loadMarketplaces() async {
        if let answer = await model.marketplaces(.skills, for: destination) {
            marketplaces = answer.marketplaces.filter { $0.format == .gitHubSkills }
        }
    }
}

/// One persona before it goes in: where it is from, the commit, the settings it sets, and
/// the whole file, front matter included.
struct PersonaPreviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let preview: DaemonAPI.PersonaPreview
    let addTo: DaemonAPI.SkillDestination
    let back: () -> Void
    let added: (DaemonAPI.ManagedPersona) -> Void

    @State private var adding = false
    @State private var failure: DaemonAPI.CatalogError?
    @State private var confirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button("‹ Results", action: back).buttonStyle(.link)
                Text(preview.persona.name).appText(.title).lineLimit(1)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        PersonaFacts(preview: preview, addTo: addTo)
                        notes
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: 300, alignment: .topLeading)
                PersonaFileReader(path: preview.path, text: preview.markdown)
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
                addButton
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Paper.wash)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Replace \(preview.persona.id)?", isPresented: $confirmingReplace) {
            Button("Replace") { Task { await add(replace: true) } }
        } message: {
            Text("The copy there now goes to the Trash.")
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let failure { PersonaNote(text: CatalogErrorWords.sentence(failure), attention: true) }
        if let problem = preview.persona.problem {
            PersonaNote(text: "Its front matter can't be read (\(problem)), so it can't be added.", attention: true)
        }
        switch preview.destinationState {
        case .unmanaged(let path):
            PersonaNote(text: "You already have a persona called \(preview.persona.id) in \(SharedFiles.tilde(URL(filePath: path).deletingLastPathComponent().path)). You made it, so the app won't replace it.",
                        attention: true)
        case .managedOther(let source):
            PersonaNote(text: "A persona of this name from \(source) is there already. Adding this one replaces it.", attention: false)
        case .sameSkill(let update):
            PersonaNote(text: update ? "An older copy of this persona is there. Adding replaces it with this commit."
                                     : "This persona is added already.", attention: false)
        case .unavailable(let error):
            PersonaNote(text: CatalogErrorWords.sentence(error), attention: true)
        case .free:
            EmptyView()
        }
    }

    @ViewBuilder
    private var addButton: some View {
        let blocked = adding || preview.persona.problem != nil
        switch preview.destinationState {
        case .unmanaged(let path):
            Button("Reveal yours") { SharedFiles.reveal(path) }.buttonStyle(.paper)
        case .sameSkill(false):
            Button("Added") {}.buttonStyle(.paper).disabled(true)
        case .managedOther, .sameSkill(true):
            Button("Replace") { confirmingReplace = true }.buttonStyle(.paperProminent).disabled(blocked)
        case .unavailable:
            Button("Add") {}.buttonStyle(.paperProminent).disabled(true)
        case .free:
            Button("Add") { Task { await add(replace: false) } }
                .buttonStyle(.paperProminent).disabled(blocked).keyboardShortcut(.defaultAction)
        }
    }

    private func add(replace: Bool) async {
        adding = true
        defer { adding = false }
        switch await model.addPersona(preview.previewID, to: addTo, replace: replace) {
        case .success(let persona): added(persona)
        case .failure(let error): failure = error
        }
    }
}

/// Update a persona added from a marketplace: its source at the current commit, as a diff
/// against the file there, with a warning above it when the runtime or the permission mode
/// changes. Nothing changes until the person says Update.
struct UpdatePersonaSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let id: String
    let destination: DaemonAPI.SkillDestination
    var onUpdated: () -> Void = {}

    @State private var answer: DaemonAPI.PersonaUpdatePreviewAnswer?
    @State private var error: DaemonAPI.CatalogError?
    @State private var updating = false
    @State private var confirmingLoss = false

    var body: some View {
        Group {
            if let answer {
                updatePane(answer)
            } else if let error {
                VStack(spacing: 0) {
                    CatalogProblemView(error: error, retry: { Task { await load() } })
                    HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(.paper) }.padding(18)
                }
            } else {
                ProgressView("Fetching \(id)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: AddSkillSheet.size.width, height: AddSkillSheet.size.height)
        .background(Paper.ground)
        .task { await load() }
    }

    private func updatePane(_ answer: DaemonAPI.PersonaUpdatePreviewAnswer) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Update \(id)").appText(.title).lineLimit(1)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(answer.changes, id: \.key) { change in
                        PersonaNote(text: Self.warning(change), attention: true)
                    }
                    if answer.edited {
                        PersonaNote(text: "You've edited this persona since it was added. Updating replaces your edits; the copy with them goes to the Trash.",
                                    attention: true)
                    }
                    if let error { PersonaNote(text: CatalogErrorWords.sentence(error), attention: true) }
                    if let problem = answer.preview.persona.problem {
                        PersonaNote(text: "The new file's front matter can't be read (\(problem)), so it can't be taken.", attention: true)
                    }
                    if answer.installed == answer.preview.markdown {
                        Text("The file is the same; only the commit moves on.").appText(.supporting)
                    } else {
                        DiffView(diff: .init(path: answer.preview.path, oldText: answer.installed,
                                             newText: answer.preview.markdown),
                                 maxHeight: nil)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                Text("From github.com/\(answer.preview.result.source) at \(answer.preview.commit.prefix(7)).")
                    .appText(.fine).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                Button("Update") {
                    if answer.edited { confirmingLoss = true } else { Task { await update(answer) } }
                }
                .buttonStyle(.paperProminent)
                .disabled(updating || answer.preview.persona.problem != nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Paper.wash)
        }
        .confirmationDialog("Your edits to \(id) will be lost", isPresented: $confirmingLoss) {
            Button("Update anyway", role: .destructive) { Task { await update(answer) } }
        } message: {
            Text("The file there was changed since it was added. Updating puts it in the Trash and takes the new one.")
        }
    }

    /// The runtime and the permission mode, old and new, in words.
    static func warning(_ change: DaemonAPI.PersonaSettingChange) -> String {
        let old = change.old ?? "not set"
        let new = change.new ?? "not set"
        switch change.key {
        case "permission-mode":
            return "This update changes the permission mode from \(old) to \(new). New sessions with this persona start with it."
        case "runtime":
            return "This update changes the runtime from \(old) to \(new). New sessions with this persona run on it."
        default:
            return "This update changes \(change.key) from \(old) to \(new)."
        }
    }

    private func load() async {
        error = nil
        switch await model.personaUpdatePreview(id, at: destination) {
        case .success(let fresh): answer = fresh
        case .failure(let failure): error = failure
        }
    }

    private func update(_ answer: DaemonAPI.PersonaUpdatePreviewAnswer) async {
        updating = true
        defer { updating = false }
        switch await model.addPersona(answer.preview.previewID, to: destination, replace: true) {
        case .success:
            onUpdated()
            dismiss()
        case .failure(let failure):
            error = failure
        }
    }
}

/// Where a persona is from and the settings it sets, as the sheet's left column lists them.
private struct PersonaFacts: View {
    let preview: DaemonAPI.PersonaPreview
    let addTo: DaemonAPI.SkillDestination

    var body: some View {
        let settings = preview.persona.settings
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            SharedFact(label: "Owner", value: preview.result.owner)
            SharedFact(label: "Repo", value: preview.result.repo)
            SharedFact(label: "Commit", value: commitLine, code: true)
            SharedFact(label: "Runtime", value: settings.runtimeID ?? "not set", code: settings.runtimeID != nil)
            SharedFact(label: "Model", value: settings.model ?? "not set", code: settings.model != nil)
            SharedFact(label: "Effort", value: settings.effort ?? "not set", code: settings.effort != nil)
            SharedFact(label: "Permission mode", value: settings.permissionMode ?? "not set",
                       code: settings.permissionMode != nil)
            SharedFact(label: "Goes to", value: goesTo, code: true)
        }
    }

    private var commitLine: String {
        let short = String(preview.commit.prefix(7))
        guard let at = preview.committedAt else { return short }
        return "\(short) · \(at.formatted(.relative(presentation: .named)))"
    }

    private var goesTo: String {
        switch addTo {
        case .personal: "~/.agents/personas/\(preview.persona.id).md"
        case .folder(let folder): SharedFiles.tilde(folder) + "/.agents/personas/\(preview.persona.id).md"
        }
    }
}

/// The whole file as it will be written, front matter included.
private struct PersonaFileReader: View {
    let path: String
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(path).appText(.code).foregroundStyle(.secondary)
                Text(text).appText(.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule, lineWidth: 1))
    }
}

private struct PersonaNote: View {
    let text: String
    let attention: Bool

    var body: some View {
        Text(text)
            .appText(.supporting)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((attention ? SharedInk.attention : SharedInk.reach).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
