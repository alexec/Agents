import AgentsKitCore
import AppKit
import SwiftUI

/// The list's state (#3321), kept by the model while the window is open, so a doc's page goes back
/// to the list as it was left.
@MainActor @Observable
final class DocsListState {
    var lists: [DocsList.HostDocs]?
    var sort = DocsList.Sort.updated
    /// A source's key, or "" for All.
    var only = ""
    /// A project's id, or "" for All projects (#3408).
    var inProject = ""
    /// The organisation's projects' names, by id; none without a control plane.
    var projectNames: [String: String] = [:]
    var query = ""
    var results: [DocsList.Result]?
    var searching = false
    var asked = 0
    /// The machine each doc was listed on, so its page reads it there first.
    var listedOn: [String: MachineRef] = [:]

    var ask: [String] { [String(asked)] }

    func load(model: AppModel) async {
        let machines = model.docsMachines
        let asked = asked
        lists = nil
        var read: [DocsList.HostDocs] = []
        for machine in machines {
            do {
                let got = try await model.docs(DaemonAPI.Method.docsList, DaemonAPI.DocsListRequest(limit: 500),
                                               returning: DaemonAPI.DocsList.self, on: machine.id)
                for doc in got.docs where listedOn[doc.ref] == nil { listedOn[doc.ref] = machine.id }
                read.append(.init(host: machine.id, name: machine.name, docs: got.docs, sources: got.sources))
            } catch {
                read.append(.init(host: machine.id, name: machine.name, problem: error.localizedDescription))
            }
        }
        await readProjectNames(model: model)
        // A newer Refresh wins.
        if asked == self.asked { lists = read }
    }

    /// The projects' names, from the control plane; a failed read keeps the last.
    func readProjectNames(model: AppModel) async {
        guard let control = model.controlRequests,
              let got = try? await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                                returning: DaemonAPI.ProjectList.self) else { return }
        projectNames = Dictionary(got.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// The project of a machine's folder, by the folder's path, as its summary names it; a project
    /// not on the list is said by the folder's own name.
    func projectOf(model: AppModel) -> DocsList.ProjectOf {
        let folders = model.folders
        let names = projectNames
        return { host, folder in
            guard let folder else { return nil }
            let wanted = Folder.standardize(URL(fileURLWithPath: folder))
            guard let summary = folders.first(where: { $0.host == host && Folder.standardize($0.folder.folder) == wanted }),
                  let id = summary.project else { return nil }
            return DocsList.Project(id: id, name: names[id] ?? summary.name)
        }
    }

    /// The sources the list shows, each project's once.
    func rows(model: AppModel) -> [DocsList.SourceRow] {
        DocsList.sources(lists ?? [], projectOf: projectOf(model: model))
    }

    func search(model: AppModel) async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { results = nil; searching = false; return }
        searching = true
        // The typing rests first; a newer search cancels this one.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        // One source is asked of each machine that has a folder of it; a connector of every machine.
        let rows = rows(model: model)
        let row = rows.first { $0.key == only }
        let shown = rows.filter { (only.isEmpty || $0.key == only) && (inProject.isEmpty || $0.project?.id == inProject) }
        var got: [(host: MachineRef, results: [DaemonAPI.DocsSearchResult])] = []
        for machine in model.docsMachines {
            let sources = row.map { DocsList.searchSources($0, on: machine.id) }
            if sources?.isEmpty == true { continue }
            let found = try? await model.docs(DaemonAPI.Method.docsSearch,
                                              DaemonAPI.DocsSearchRequest(query: words, sources: sources, limit: 50),
                                              returning: DaemonAPI.DocsSearch.self, on: machine.id)
            got.append((machine.id, found?.results ?? []))
        }
        guard !Task.isCancelled else { return }
        for list in got { for r in list.results where listedOn[r.doc.ref] == nil { listedOn[r.doc.ref] = list.host } }
        results = DocsList.results(DocsList.merged(got), in: shown)
        searching = false
    }
}

/// Docs (#3321, spec 3319), as the web page's Docs section: every machine's docs (`docs/list`),
/// grouped by source (each project once, #3408), a folder's by its subfolders, with a Project filter; search (`docs/search`) with each match's line
/// and snippet; and a doc's page (`docs/read`), read only. Back and Forward go along the places.
struct DocsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let place = model.docsHistory.current ?? DocsPlace()
        Group {
            if let ref = place.ref {
                DocPage(ref: ref, line: place.line).id(place)
            } else {
                DocsListPane(list: model.docsList)
            }
        }
        .navigationTitle("Docs")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.docsHistory.back() } label: { Image(toolbarIcon: "chevron.left") }
                    .disabled(!model.docsHistory.canGoBack)
                    .help("Back")
                Button { model.docsHistory.forward() } label: { Image(toolbarIcon: "chevron.right") }
                    .disabled(!model.docsHistory.canGoForward)
                    .help("Forward")
            }
        }
    }
}

private struct DocsListPane: View {
    @Environment(AppModel.self) private var model
    @Bindable var list: DocsListState

    private var words: String { list.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            filters.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .task(id: list.ask) { await list.load(model: model) }
        .task(id: [list.query, list.only, list.inProject]) { await list.search(model: model) }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            TextField("Search docs", text: $list.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search docs")
            let rows = list.rows(model: model)
            let projects = DocsList.projects(rows)
            if !projects.isEmpty {
                Picker("Project", selection: $list.inProject) {
                    Text("All projects").tag("")
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
                .onChange(of: list.inProject) { _, project in
                    // A source of another project is not in the list any more.
                    if !project.isEmpty, rows.first(where: { $0.key == list.only })?.project?.id != project { list.only = "" }
                }
            }
            Picker("Source", selection: $list.only) {
                Text("All").tag("")
                ForEach(rows.filter { list.inProject.isEmpty || $0.project?.id == list.inProject }) { Text($0.heading).tag($0.key) }
            }
            .fixedSize()
            if words.isEmpty {
                Picker("Sort", selection: $list.sort) {
                    ForEach(DocsList.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
            Button("Refresh") { list.asked += 1 }
                .linkStyle()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.docsMachines.isEmpty {
            message(DocsList.noDocsHere)
        } else if !words.isEmpty {
            results
        } else if let lists = list.lists {
            let groups = DocsList.groups(lists, sort: list.sort, only: list.only, projectOf: list.projectOf(model: model),
                                         project: list.inProject)
            List {
                ForEach(lists.compactMap { l in l.problem.map { "\(l.name): \($0)" } }, id: \.self) { line in
                    Label(line, icon: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                if groups.isEmpty {
                    Text(DocsList.noDocs).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    Section {
                        if group.row.source.kind == .folder, let problem = DocsList.problem(group.row.source) {
                            Text(problem).foregroundStyle(.secondary)
                        } else if group.row.source.state == .read, group.shelves.isEmpty {
                            Text("No docs.").appText(.fine).foregroundStyle(.secondary)
                        }
                        ForEach(group.shelves) { shelf in
                            if !shelf.dir.isEmpty {
                                Text("▸ \(shelf.dir)").appText(.supporting).foregroundStyle(.secondary)
                            }
                            ForEach(shelf.docs) { doc in
                                Button { model.showDocs(DocsPlace(ref: doc.ref)) } label: {
                                    DocRow(doc: doc, name: DocsList.underShelf(doc, shelf.dir))
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, shelf.dir.isEmpty ? 0 : 16)
                                .help(doc.ref)
                            }
                        }
                    } header: {
                        sourceHeading(group.row)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceHeading(_ row: DocsList.SourceRow) -> some View {
        HStack(spacing: 8) {
            Text(row.heading.uppercased()).appText(.fine).fontWeight(.semibold)
            if row.source.kind == .connector, let problem = DocsList.problem(row.source) {
                Text("— \(problem)").appText(.fine).foregroundStyle(.secondary)
            }
            if row.source.state == .notMapped, let folder = row.source.folder {
                Button("Map it…") {
                    _ = model.offerStart(AppViewStart(prompt: DocsList.mapItPrompt(row.source)),
                                         in: FolderKey(host: row.host, folder: URL(fileURLWithPath: folder)))
                }
                .linkStyle()
                .help("Start an agent that maps this docs server’s search and read tools")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var results: some View {
        if let results = list.results, !results.isEmpty {
            List {
                ForEach(results) { found in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { model.showDocs(DocsPlace(ref: found.result.doc.ref)) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(found.result.doc.title).fontWeight(.semibold).lineLimit(1)
                                if let path = found.result.doc.path {
                                    Text(path).appText(.fine).monospaced().foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(found.result.doc.ref)
                        ForEach(Array(found.result.matches.enumerated()), id: \.offset) { _, match in
                            Button { model.showDocs(DocsPlace(ref: found.result.doc.ref, line: match.line)) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(match.line.map(String.init) ?? "")
                                        .monospacedDigit().foregroundStyle(.secondary)
                                        .frame(minWidth: 32, alignment: .trailing)
                                    Text(match.snippet).lineLimit(2).foregroundStyle(.tint)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset)
        } else {
            message(list.searching || list.results == nil ? "Searching…" : DocsList.noResults)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A row: a folder doc's path and its title beside it, or a connector doc's title; when it changed.
private struct DocRow: View {
    let doc: DaemonAPI.Doc
    let name: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if doc.path != nil {
                Text(name).monospaced().lineLimit(1)
            } else {
                Text(name).fontWeight(.semibold).lineLimit(1)
            }
            if let beside = DocsList.titleBeside(doc) {
                Text(beside).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(DocsList.updatedWords(doc)).appText(.fine).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// A doc's page: its title, ref and when it changed; Open in Files or in its vendor's app, Copy
/// link and Copy ref; and its Markdown, drawn as the Files pane draws a page, read only. A folder
/// doc's page follows the file: it reads it again every few seconds while it is shown.
private struct DocPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let ref: String
    let line: Int?

    @State private var reading: (host: MachineRef, reading: DaemonAPI.DocsReading)?
    @State private var problem: String?
    @State private var copied: String?
    @State private var startProblem: String?

    /// How often a folder doc is read again while its page is shown.
    private static let followEvery: Duration = .seconds(5)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if let problem {
                Text(problem).foregroundStyle(.secondary).padding(16)
                Spacer()
            } else if let reading {
                if let next = reading.reading.next {
                    Text("Showing lines \(reading.reading.from)–\(reading.reading.to) of \(reading.reading.lines); the rest from line \(next) is not shown.")
                        .appText(.fine).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 6)
                }
                LivePage(text: reading.reading.text, url: pageURL(reading.reading.doc), line: line)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ref) {
            // The names, for the project the page says, while the doc is read.
            if model.docsList.projectNames.isEmpty { Task { await model.docsList.readProjectNames(model: model) } }
            await read()
        }
    }

    private var doc: DaemonAPI.Doc? { reading?.reading.doc }

    private var project: DocsList.Project? {
        guard let reading else { return nil }
        return model.docsList.projectOf(model: model)(reading.host, reading.reading.doc.folder)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(doc.map(DocsList.shortForm) ?? ref).appText(.title).lineLimit(2)
            // The project it is in (#3408), as an issue's or a PR's page says it.
            Text([project?.name ?? "", ref, doc.map { "updated " + DocsList.updatedWords($0) } ?? ""]
                .filter { !$0.isEmpty && $0 != "updated " }
                .joined(separator: " · "))
                .appText(.fine).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                if let doc, let host = reading?.host { startMenu(doc, on: host) }
                if let doc, !DocsList.isFolderDoc(doc), let url = doc.url.flatMap(URL.init(string:)) {
                    Button("Open in \(DocsList.vendorName(ref))") { openURL(url) }
                } else if let doc, let place = filesPlace(doc) {
                    Button("Open in Files") { _ = model.showDocFile(place.path, folder: place.folder, on: place.host) }
                        .help("Open this file as the folder’s page")
                }
                Button(copied == "link" ? "Copied" : "Copy link") { copy("link", DocsList.windowAddress(ref)) }
                    .help(DocsList.windowAddress(ref))
                Button(copied == "ref" ? "Copied" : "Copy ref") { copy("ref", ref) }
                    .help(ref)
                Spacer(minLength: 0)
                Button("All docs") { model.showDocs(DocsPlace()) }
                    .linkStyle()
            }
            if let startProblem {
                SheetNote(text: startProblem, reservesSpace: false)
            }
        }
    }

    /// Start Agent ▾ (#3322): a new session from this doc, in its folder; a connector doc's asks
    /// for the folder, as each start's own menu of this machine's folders.
    @ViewBuilder
    private func startMenu(_ doc: DaemonAPI.Doc, on host: MachineRef) -> some View {
        Menu("Start Agent") {
            ForEach(DocsList.Start.allCases, id: \.self) { start in
                if DocsList.isFolderDoc(doc) {
                    Button(start.title) { self.start(start, doc, in: doc.folder ?? "", on: host) }
                        .help(start.help)
                } else {
                    Menu(start.title) {
                        let folders = model.folders.filter { $0.host == host }
                        if folders.isEmpty { Text("No folder on this machine") }
                        ForEach(folders) { folder in
                            Button(folder.name) { self.start(start, doc, in: folder.folder.folder.path, on: host) }
                        }
                    }
                    .help(start.help)
                }
            }
        }
        .fixedSize()
        .help(DocsList.isFolderDoc(doc) ? "A new session in this doc’s folder, working from it"
            : "A new session working from this doc, in a folder you choose")
    }

    private func start(_ start: DocsList.Start, _ doc: DaemonAPI.Doc, in folder: String, on host: MachineRef) {
        startProblem = folder.isEmpty ? "This doc has no folder here." : model.offerStart(
            AppViewStart(prompt: start.prompt(doc.ref), labels: start.labels(doc)),
            in: FolderKey(host: host, folder: URL(fileURLWithPath: folder)))
    }

    private func copy(_ what: String, _ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == what { copied = nil }
        }
    }

    /// Where Open in Files goes: the folder's own page of the file, as a pinned page opens.
    private func filesPlace(_ doc: DaemonAPI.Doc) -> (path: String, folder: String, host: MachineRef)? {
        guard let host = reading?.host, let folder = doc.folder, let path = doc.path else { return nil }
        return (path, folder, host)
    }

    /// The document's own place, so a picture beside a folder doc can be found.
    private func pageURL(_ doc: DaemonAPI.Doc) -> URL {
        if let folder = doc.folder, let path = doc.path {
            return URL(fileURLWithPath: folder).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: "/").appendingPathComponent(doc.title.isEmpty ? "doc" : doc.title)
    }

    /// The machine that listed it first, then this Mac, then the others; and again every few seconds
    /// for a folder doc.
    private func read() async {
        let machines = model.docsMachines
        let first = model.docsList.listedOn[ref]
        let order = machines.filter { $0.id == first } + machines.filter { $0.id != first }
        var last: String?
        for machine in order {
            do {
                let got = try await model.docs(DaemonAPI.Method.docsRead, DaemonAPI.DocsReadRequest(ref: ref),
                                               returning: DaemonAPI.DocsReading.self, on: machine.id)
                reading = (machine.id, got)
                problem = nil
                await follow(on: machine.id)
                return
            } catch {
                if Task.isCancelled { return }
                last = error.localizedDescription
            }
        }
        problem = machines.isEmpty ? DocsList.noDocsHere : last ?? "No machine here has this doc."
    }

    private func follow(on host: MachineRef) async {
        guard let doc, DocsList.isFolderDoc(doc) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.followEvery)
            guard !Task.isCancelled else { return }
            if let got = try? await model.docs(DaemonAPI.Method.docsRead, DaemonAPI.DocsReadRequest(ref: ref),
                                               returning: DaemonAPI.DocsReading.self, on: host),
               got.text != reading?.reading.text {
                reading = (host, got)
            }
        }
    }
}
