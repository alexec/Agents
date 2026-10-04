import AgentsKitCore
import SwiftUI

/// The agent's folder, and what is in it.
///
/// Read-only, deliberately (004 FR-017), with one exception that 022 made: a Markdown
/// file opens as a live page the person can type on, and what they type goes to disk
/// through the daemon. Nothing else here creates, renames, deletes or edits; the
/// terminal pane is still the escape hatch for the rest.
///
/// The phone has the same pane since 034, reading through the daemon's `files/*` rather
/// than this disk, with the same page and the same one exception.
struct FilesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    @Environment(WebHolders.self) private var holders
    @Environment(\.openURL) private var openURL
    let agent: Agent
    let state: AgentPaneState

    /// Every folder read so far, by path: the top, and each one opened in the tree.
    @State private var listings: [String: DirectoryListing] = [:]
    @State private var problems: [String: String] = [:]
    @State private var probe: FileProbe?
    @State private var fileProblem: String?
    /// The file is not there (as against not read): a Markdown page then keeps what it had.
    @State private var fileGone = false
    @State private var touched = TouchedPaths()
    /// Which stretch of whose conversation `touched` has folded, by position in the
    /// whole transcript. Entries outside it — new at the end, or an earlier page in
    /// front — are folded in; anything else is folded again from the top.
    @State private var touchedAgent: UUID?
    @State private var touchedFrom = 0
    @State private var touchedTo = 0
    /// Which re-listing of each folder is the current one, so a slower earlier read
    /// landing after a later one does not put the older listing on screen.
    @State private var listingRequests: [String: Int] = [:]
    /// Folders with a read on its way, so one waiting for its parent is asked for once.
    @State private var reading: Set<String> = []
    /// The file `probe` was read from, so a file opened from elsewhere is loaded once
    /// and not once for every pass.
    @State private var loaded: URL?
    /// Counted up on every file read, so a slow read of one file landing after the
    /// person has opened another does not show under the other's name (#89).
    @State private var fileRequest = 0
    /// Counted up on every folder event and handed to the page, which re-reads its
    /// pictures' stamps on each: a redrawn image changes no text (022 FR-020).
    @State private var folderEvents = 0
    /// The file the person just chose from a row of the tree, which is in view already.
    @State private var chosenFromRow: URL?
    /// What the Changes pane lists, by path, so a changed file shows its status and
    /// counts here too, and a folder what changed under it (#63).
    @State private var changes = ChangeTree.Index()
    /// Bumped when the list could have changed; asking is keyed on it, so a burst of
    /// folder events collapses into one ask.
    @State private var changesRevision = 0

    private var folder: URL { state.folder ?? agent.cwd }

    /// The top of the tree: the agent's folder, with whatever was asked for inside it
    /// opened down to; or, for something outside it, that folder on its own.
    private var root: URL { Self.isInside(folder, agent.cwd) ? agent.cwd : folder }

    /// Every host's folder is read through that host (037), this Mac's included (058, R11).
    private var server: RemoteFiles { model.serverFiles(agent.host) }
    /// Where a file the pane will not draw is, when Finder here cannot show it: nil for
    /// this Mac's host, whose files the window reveals and opens through it.
    private var elsewhere: String? { model.isOnThisMac(agent.host) ? nil : model.hosts.label(agent.host) }
    /// Anything changed under the agent's folders: the tree shows more than the top one.
    private var serverChanges: Int { server.anyChange[agent.id] ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The tree stays under an open file rather than going, so Back finds it as
            // it was left: scrolled where it was, the file's row marked (#66).
            ZStack {
                listingView
                    .opacity(state.openFile == nil ? 1 : 0)
                    .allowsHitTesting(state.openFile == nil)
                    .accessibilityHidden(state.openFile != nil)
                if let openFile = state.openFile {
                    fileView(openFile)
                }
            }
        }
        .task(id: agent.id) { await start() }
        .onDisappear {
            let server = server
            Task { await server.unwatch(agentID: agent.id, folder: agent.cwd) }
        }
        // The host says `files/changed` when the folder changes.
        .onChange(of: serverChanges) {
            folderEvents += 1
            changesRevision += 1
            reloadListings(inBackground: true)
            if let openFile = state.openFile { reloadFile(openFile) }
        }
        // The host is back on a new connection: whatever is open is read again, and a
        // folder that said it could not be read gets another go (#62).
        .onChange(of: server.reconnections) {
            reloadListings(inBackground: true)
            if let openFile = state.openFile { reloadFile(openFile) }
        }
        .onChange(of: model.entries.count) { refreshTouched() }
        // Hidden panes are kept alive, so this one only asks while it is shown.
        .task(id: ChangesAsk(shown: frame.pane == .files, revision: changesRevision)) {
            guard frame.pane == .files else { return }
            // A moment's pause, so the folder events of one save are one ask.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await fetchChanges()
        }
        .onChange(of: agent.state) { changesRevision += 1 }
        // The agent moved to another folder (053): the pane goes with it, from the top,
        // and stops watching the one it left.
        .onChange(of: agent.cwd) { old, new in
            guard old != new else { return }
            let server = server
            Task { await server.unwatch(agentID: agent.id, folder: old) }
            state.folder = new
            state.expanded = []
            state.openFile = nil
            state.openLine = nil
            state.place.forget()
            loaded = nil
            probe = nil
            listings = [:]
            problems = [:]
            reading = []
            reloadListings()
            startWatching()
        }
        // A file opened from elsewhere — the chat, a permission card — names its folder,
        // and the tree opens down to it so Back finds it in place.
        .onChange(of: state.folder) {
            reveal(folder)
            reloadListings()
        }
        // The agent can open a file here as well as the user (`show_file`), and when
        // it does, this pane is already on screen and has already run its task.
        .onChange(of: state.openFile) { _, url in
            guard let url else { return }
            // Marked in the tree, and opened down to, so Back has it in view: from the
            // Changes pane it comes with no folder of its own.
            state.place.opened(url, fromRow: url == chosenFromRow)
            chosenFromRow = nil
            reveal(url.deletingLastPathComponent())
            readUnread()
            guard url != loaded else { return }
            reloadFile(url)
        }
    }

    // MARK: The bar at the top

    private var header: some View {
        HStack(spacing: 6) {
            if state.openFile != nil {
                Button {
                    state.openFile = nil
                    state.openLine = nil
                    loaded = nil
                    probe = nil
                    fileProblem = nil
                    fileGone = false
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            } else if root != agent.cwd {
                Button {
                    state.folder = nil
                } label: {
                    Label("The agent's folder", systemImage: "house")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("The agent's folder")
            }

            Text(state.openFile?.lastPathComponent ?? root.lastPathComponent)
                .appText(.reading).fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let openFile = state.openFile, canDrawPage(openFile) {
                pageControls(openFile)
            }
            if let openFile = state.openFile, let path = pinPath(openFile) {
                pinButton(path)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The open file's path in the project, when it is a page that can be pinned (#159):
    /// from a worktree, the same path in the project folder, where the pin opens it.
    private func pinPath(_ url: URL) -> String? {
        let file = url.path(percentEncoded: false)
        let path = agent.worktree != nil
            ? PinRules.relative(file, in: agent.cwd) : PinRules.relative(file, in: agent.projectFolder)
        return path.flatMap { PinRules.kind($0) == nil ? nil : $0 }
    }

    /// Pin to Project, or Unpin when it is pinned: beside the Dashboard, under the project.
    @ViewBuilder
    private func pinButton(_ path: String) -> some View {
        let project = ProjectKey(host: agent.host, folder: agent.projectFolder)
        let pins = model.pins(in: project.folder)
        if pins.contains(where: { $0.path == path }) {
            Button { Task { await model.unpin(path, in: project) } } label: {
                Label("Unpin", systemImage: "pin.fill").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Pinned under the project. Click to unpin it.")
        } else {
            let full = pins.count >= PinLimits.perProject
            Button { Task { await model.pin(path, in: project) } } label: {
                Label("Pin to Project", systemImage: "pin").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(full)
            .help(full ? "This project already has \(PinLimits.perProject) pinned pages, the most it can have. Unpin one first."
                       : "Pin to Project: under the project in the sidebar, beside its Dashboard.")
        }
    }

    /// An HTML file's two ways of being read (#67): the page or its source, one choice
    /// for the pane; and, on the page, whether this file may run scripts.
    @ViewBuilder
    private func pageControls(_ url: URL) -> some View {
        @Bindable var state = state
        let path = url.path(percentEncoded: false)
        if !state.htmlShowsSource {
            Toggle(isOn: Binding(get: { state.scriptsAllowed.contains(path) },
                                 set: { allowed in
                                     if allowed { state.scriptsAllowed.insert(path) } else { state.scriptsAllowed.remove(path) }
                                 })) {
                Label("Allow scripts", systemImage: "curlybraces")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(state.scriptsAllowed.contains(path)
                  ? "Scripts run on this page, with no network. Click to stop them."
                  : "Scripts are off on this page. Click to let them run, with no network.")
        }
        Picker("Show", selection: $state.htmlShowsSource) {
            Text("Page").tag(false)
            Text("Source").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    /// An HTML file the pane has whole: one cut at the read limit is source only, with
    /// the note saying so, never half a page.
    private func canDrawPage(_ url: URL) -> Bool {
        guard HTMLPageScope.isHTML(url), fileProblem == nil, let probe else { return false }
        return probe.kind.isText && !probe.isTruncated
    }

    /// Where a link the person clicked on a page goes. Never into the file view itself.
    private func follow(_ link: HTMLPageScope.LinkDecision) {
        switch link {
        case .openFile(let path):
            open(file: URL(filePath: path))
        case .openOutside(let url):
            // The person's own click, so the Browser pane may go there (FR-035 is about
            // the agent driving it, which this is not); mail and the rest go to their app.
            if BrowserPolicy.decide(url).isAllowed, ["http", "https"].contains(url.scheme?.lowercased()) {
                state.browserURL = url
                holders.holder(for: agent.id).load(url)
                frame.pane = .browser
            } else {
                openURL(url)
            }
        case .stay, .ignore:
            break
        }
    }

    // MARK: The folder

    @ViewBuilder
    private var listingView: some View {
        if let problem = problems[Self.key(root)] {
            Gone(message: problem) { reloadListing(of: root) }
        } else if listings[Self.key(root)] != nil {
            let lines = treeLines
            ScrollViewReader { reader in
                List {
                    ForEach(lines) { line in
                        switch line {
                        case .entry(let entry, let depth):
                            row(entry, depth: depth)
                        case .note(_, let words, let depth):
                            Text(words)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .padding(.leading, indent(depth))
                        case .problem(let folder, let words, let depth):
                            HStack(spacing: 8) {
                                Text(words)
                                    .appText(.fine)
                                    .foregroundStyle(.secondary)
                                Button("Try Again") { reloadListing(of: folder) }
                                    .appText(.fine)
                                    .buttonStyle(.link)
                            }
                            .padding(.leading, indent(depth))
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onAppear { bringMarkedIntoView(lines, reader) }
                .onChange(of: lines.map(\.id)) { bringMarkedIntoView(lines, reader) }
                .onChange(of: state.place.toScroll) { bringMarkedIntoView(lines, reader) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One line of the tree, as the list draws it.
    private enum TreeLine: Identifiable {
        case entry(DirectoryEntry, depth: Int)
        case note(id: String, String, depth: Int)
        /// A folder that could not be read, with a way to try again.
        case problem(URL, String, depth: Int)

        var id: String {
            switch self {
            case .entry(let entry, _): entry.url.absoluteString
            case .note(let id, _, _): id
            case .problem(let folder, _, _): "problem:\(FilesPane.key(folder))"
            }
        }
    }

    /// The tree, flattened top to bottom: each open folder's entries under it, one
    /// step in. A folder opened before it has been read says so on a line of its own.
    private var treeLines: [TreeLine] {
        var lines: [TreeLine] = []
        func add(_ folder: URL, depth: Int) {
            let key = Self.key(folder)
            if let problem = problems[key] {
                lines.append(.problem(folder, problem, depth: depth))
                return
            }
            guard let listing = listings[key] else {
                lines.append(.note(id: "reading:\(key)", "Reading…", depth: depth))
                return
            }
            for entry in listing.entries {
                lines.append(.entry(entry, depth: depth))
                if entry.isDirectory, state.expanded.contains(Self.key(entry.url)) {
                    add(entry.url, depth: depth + 1)
                }
            }
            if listing.isTruncated {
                lines.append(.note(id: "omitted:\(key)", "\(listing.omitted) more, not shown", depth: depth))
            }
        }
        add(root, depth: 0)
        return lines
    }

    /// The folders on screen: the top, and every open one whose parents are open too.
    /// Only these are read again when the disk changes.
    private var visibleFolders: [URL] {
        FileTree.visibleFolders(root: root, expanded: state.expanded, listings: listings)
    }

    /// Every open folder on screen that has nothing to show and no read on its way: one
    /// opened before its parent had been read, as when the pane is drawn afresh with
    /// folders still open, or a file deep in the tree is revealed (#62).
    private func readUnread() {
        for folder in FileTree.unread(root: root, expanded: state.expanded, listings: listings,
                                      problems: Set(problems.keys), reading: reading) {
            reloadListing(of: folder)
        }
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 14 }

    /// Scroll the marked file's row into view, once its folder has been read. Whether
    /// the tree is on screen or under the file, so Back finds it there either way.
    private func bringMarkedIntoView(_ lines: [TreeLine], _ reader: ScrollViewProxy) {
        guard state.place.toScroll != nil else { return }
        var rows: [String: String] = [:]
        for line in lines {
            if case .entry(let entry, _) = line, !entry.isDirectory { rows[Self.key(entry.url)] = line.id }
        }
        guard let key = state.place.scroll(among: rows.keys), let id = rows[key] else { return }
        // After this pass: a list that has only just appeared has not been laid out.
        Task { reader.scrollTo(id, anchor: .center) }
    }

    private func row(_ entry: DirectoryEntry, depth: Int) -> some View {
        let key = Self.key(entry.url)
        let isOpen = entry.isDirectory && state.expanded.contains(key)
        let isMarked = !entry.isDirectory && state.place.marked == key
        let action = {
            if entry.isDirectory {
                toggle(folder: entry.url)
            } else {
                open(file: entry.url)
            }
        }
        return Group {
            if entry.isDirectory {
                // A folder holding changes says how much changed under it, closed or
                // open, so the agent's work deep in the tree can still be found (#63).
                let totals = changes.folders[key]
                FileTreeRow(name: entry.name, kind: .folder(open: isOpen), depth: depth,
                            label: totals.map { "\(entry.name), folder, \(ChangeWords.label($0))" }
                                ?? "\(entry.name), folder",
                            added: totals?.added, removed: totals?.removed, action: action)
            } else if let file = changes.files[key] {
                // What the agent changed since it started (FR-013), in the same square
                // and colour as the Changes pane: its work is findable without reading
                // the conversation.
                FileTreeRow(changed: file, name: entry.name, depth: depth, action: action)
            } else if touched.contains(entry.url) {
                // Touched in the conversation, before the list has caught up with it.
                FileTreeRow(name: entry.name, kind: .file(.modified), depth: depth,
                            label: "\(entry.name), changed", help: "The agent changed this",
                            action: action)
            } else {
                FileTreeRow(name: entry.name, kind: .file(nil), depth: depth, label: entry.name,
                            action: action)
            }
        }
        // The file last open, so Back shows where it is (#66).
        .accessibilityAddTraits(isMarked ? .isSelected : [])
        .listRowBackground(Group {
            if isMarked {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Paper.accent.opacity(0.18))
                    .padding(.horizontal, 10)
            }
        })
    }

    private struct ChangesAsk: Equatable {
        var shown: Bool
        var revision: Int
    }

    /// The Changes pane's list, keyed as this tree keys its rows. git answers with the
    /// folder's real path (`/private/tmp/…`), the tree with the one the agent was given.
    private func fetchChanges() async {
        guard let list = try? await model.changes(for: agent.id) else { return }
        let shown = Self.key(agent.cwd)
        let real = Self.key(agent.cwd.resolvingSymlinksInPath())
        let files = list.files.map { file in
            var file = file
            if real != shown, file.path.hasPrefix(real + "/") {
                file.path = shown + file.path.dropFirst(real.count)
            }
            return file
        }
        let index = ChangeTree.Index(files)
        if index != changes { changes = index }
    }

    // MARK: One file

    @ViewBuilder
    private func fileView(_ url: URL) -> some View {
        if isMarkdown(url), (fileProblem != nil && (fileGone || probe != nil)) || probe?.kind.isText == true {
            // Markdown reads as a page, and the page is live: it follows the file as
            // the agent writes it (022). A line an agent named no longer forces the
            // source view — the page has a passage for every line, and goes to the
            // one that holds it (FR-007).
            //
            // One view whether the file is there or not, so that its state — a
            // passage the person is typing in — survives the file going. Before the
            // first write the agent has shown a file that is not there yet, and the
            // page opens empty and fills when it appears; after a delete, the page
            // keeps the last content it had, so nothing the person was reading or
            // typing vanishes. Said in a line either way.
            VStack(alignment: .leading, spacing: 0) {
                if let fileProblem {
                    Text(probe == nil ? "Not written yet. It will appear here as it is." : fileProblem)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    Divider()
                }
                LivePage(text: probe?.text ?? "", url: url, line: state.openLine,
                         agentName: RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID,
                         folderEvent: folderEvents)
                    // The page is shared with the phone (034); where it saves and how it
                    // reads a picture are the Mac's.
                    .environment(\.pageActions, MacPageActions.make(model: model, agentID: agent.id))
                if let probe, probe.isTruncated {
                    Divider()
                    Text("Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(probe.prefix.count), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(probe.size), countStyle: .file)).")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
        } else if canDrawPage(url), !state.htmlShowsSource, let probe {
            // HTML reads as a page by default (#67), live as the Markdown page is: it
            // reloads, in place, when the file or anything beside it changes. What the
            // page may do is decided in `HTMLPage`.
            let server = server
            let agentID = agent.id
            let path = url.path(percentEncoded: false)
            HTMLPage(text: probe.text ?? "", path: path,
                     scope: HTMLPageScope(file: url, agentFolder: agent.cwd),
                     allowsScripts: state.scriptsAllowed.contains(path),
                     folderEvent: folderEvents,
                     read: { try await server.read(agentID: agentID, path: $0) },
                     follow: follow)
        } else if let fileProblem {
            Gone(message: fileProblem) { reloadFile(url) }
        } else if let probe {
            switch probe.kind {
            case .text:
                VStack(alignment: .leading, spacing: 0) {
                    // Everything that is not Markdown: numbered source, as it was.
                    FileLines(text: probe.text ?? "", line: state.openLine, path: url.path)
                    if probe.isTruncated {
                        Divider()
                        Text("Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(probe.prefix.count), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(probe.size), countStyle: .file)).")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
            case .image(let description):
                ImageFile(url: url, probe: probe, description: description,
                          elsewhere: elsewhere, host: agent.host)
            case .binary(let description):
                // Its bytes are never shown (FR-014). What is shown is the way out.
                OpenElsewhere(url: url, description: description, server: elsewhere, host: agent.host)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Doing

    private func start() async {
        refreshTouched()
        // The open file is left alone: the pane is arriving, not being navigated. When the agent asked for a file the sidebar
        // was usually shut, so this is the first pass and the file it named is sitting
        // in `state` waiting to be read. Clearing it here showed the folder instead,
        // which looked like `show_file` having done nothing at all.
        state.folder = folder
        reveal(folder)
        // A tree drawn new starts at the top: the file open, or last open, is found again.
        if let openFile = state.openFile {
            state.place.opened(openFile, fromRow: false)
            reveal(openFile.deletingLastPathComponent())
        } else {
            state.place.drawnAfresh()
        }
        reloadListings()
        // Not `open(file:)` either, for the same reason at one remove: that treats the
        // file as the user's own choice and throws away the line the agent named.
        if let openFile = state.openFile { reloadFile(openFile) }
        startWatching()
    }

    private func startWatching() {
        let server = server
        Task { await server.watch(agentID: agent.id, folder: agent.cwd) }
    }

    /// Open a folder in place, or close it. Opening reads it again even when it was
    /// read before: what it held then may not be what it holds now.
    private func toggle(folder url: URL) {
        let key = Self.key(url)
        if state.expanded.contains(key) {
            state.expanded.remove(key)
        } else {
            state.expanded.insert(key)
            reloadListing(of: url, inBackground: listings[key] != nil)
        }
    }

    /// Open every folder between the agent's and the one asked for.
    private func reveal(_ folder: URL) {
        let top = Self.key(agent.cwd), target = Self.key(folder)
        guard target != top, target.hasPrefix(top + "/") else { return }
        var url = agent.cwd
        for part in target.dropFirst(top.count + 1).split(separator: "/") {
            url = url.appending(path: String(part), directoryHint: .isDirectory)
            state.expanded.insert(Self.key(url))
        }
    }

    /// A path as the tree keys it: no trailing slash, whichever way the URL was made.
    fileprivate static func key(_ url: URL) -> String { FileTree.key(url) }

    private static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = key(url), top = key(folder)
        return path == top || path.hasPrefix(top + "/")
    }

    /// Every folder on screen, read again.
    private func reloadListings(inBackground: Bool = false) {
        for folder in visibleFolders {
            reloadListing(of: folder, inBackground: inBackground)
        }
    }

    private func open(file url: URL) {
        chosenFromRow = url
        state.openFile = url
        // The user's own choice of file starts at the top. A line is where an agent
        // asked them to look, and that is only true of the file the agent named.
        state.openLine = nil
        reloadFile(url)
    }

    /// Read a folder now, or — for a change the disk reported rather than one the
    /// person made — on another thread, with the old listing kept up until the new
    /// one is in hand. Opening a folder stays on this thread so it appears in the
    /// same frame as the click.
    private func reloadListing(of folder: URL, inBackground: Bool = false) {
        let key = Self.key(folder)
        let request = (listingRequests[key] ?? 0) + 1
        listingRequests[key] = request
        reading.insert(key)
        let server = server
        let agentID = agent.id
        Task {
            let read: Result<DirectoryListing, any Error>
            do { read = .success(try await server.list(agentID: agentID, folder: folder)) }
            catch { read = .failure(error) }
            // A slower earlier read landing after a later one is dropped. The later one
            // always ends, with a listing or a sentence: `RemoteFiles` gives up on a
            // read nobody answers.
            guard request == listingRequests[key] else { return }
            reading.remove(key)
            if case .failure(let error) = read {
                listings[key] = nil
                problems[key] = RemoteFiles.describe(error, name: folder.lastPathComponent)
            } else {
                show(read, of: folder)
                readUnread()
            }
        }
    }

    private func show(_ read: Result<DirectoryListing, any Error>, of folder: URL) {
        let key = Self.key(folder)
        switch read {
        case .success(let fresh):
            if listings[key] != fresh { listings[key] = fresh }
            problems[key] = nil
        case .failure:
            listings[key] = nil
            problems[key] = "\(folder.lastPathComponent) could not be read."
        }
    }

    private func reloadFile(_ url: URL) {
        loaded = url
        fileRequest += 1
        let request = fileRequest
        let server = server
        let agentID = agent.id
        Task {
            do {
                let reading = try await server.read(agentID: agentID, path: url.path(percentEncoded: false))
                // Only the latest read is shown, whichever file it was for.
                guard request == fileRequest, let fresh = Self.probe(reading) else { return }
                // The watch is on the whole folder, so a build writing beside this file
                // lands here too. Unchanged bytes are not news.
                if let probe, probe.prefix == fresh.prefix, probe.size == fresh.size { fileProblem = nil; fileGone = false; return }
                probe = fresh
                fileProblem = nil
                fileGone = false
            } catch {
                guard request == fileRequest else { return }
                // A Markdown page keeps what it last had (022); source has nothing to
                // keep that the listing does not say better.
                fileGone = RemoteFiles.isGone(error)
                if !(fileGone && isMarkdown(url)) { probe = nil }
                fileProblem = RemoteFiles.describe(error, name: url.lastPathComponent)
            }
        }
    }

    /// What a server read looks like to the pane, which was written for the disk's.
    private static func probe(_ reading: FileReading) -> FileProbe? {
        switch reading {
        case .text(let text, let isTruncated, let size, _):
            FileProbe(kind: .text, prefix: Data(text.utf8), isTruncated: isTruncated, size: size)
        case .image(let bytes, let describedAs, _):
            FileProbe(kind: .image(describedAs: describedAs), prefix: bytes, isTruncated: false, size: bytes.count)
        case .other(let describedAs, let size, _):
            FileProbe(kind: .binary(describedAs: describedAs), prefix: Data(), isTruncated: false, size: size)
        case .unchanged:
            nil
        }
    }

    /// The kit's list, so the daemon's idea of a page and the pane's are one.
    private func isMarkdown(_ url: URL) -> Bool { ShownFile.isMarkdown(url) }

    /// Folded from the transcript the window is holding.
    ///
    /// Only what is new to the fold is folded in: entries arriving at the end, and an
    /// earlier page put in front. Folding the whole page for every chunk resolved every
    /// path the agent had touched against the disk again, several times a second, while
    /// the agent talked. And a page trimmed at the front keeps its marks: the model
    /// lets the oldest entries of a long conversation go, and the agent still touched
    /// what they say it touched.
    private func refreshTouched() {
        let before = touched
        defer { if touched != before { changesRevision += 1 } }
        let entries = model.entries
        let from = model.work.firstEntryIndex
        let to = from + entries.count
        if touchedAgent == model.work.watching, from <= touchedTo {
            let front = min(max(touchedFrom - from, 0), entries.count)
            let back = min(max(touchedTo - from, front), entries.count)
            for entry in entries[..<front] { touched.absorb(entry) }
            for entry in entries[back...] { touched.absorb(entry) }
            touchedFrom = min(touchedFrom, from)
            touchedTo = max(touchedTo, to)
        } else {
            touched = TouchedPaths(entries: entries)
            touchedAgent = model.work.watching
            touchedFrom = from
            touchedTo = to
        }
    }
}

/// What a pane says when the thing it was showing has gone.
private struct Gone: View {
    let message: String
    /// Try Again, for a read that failed rather than a thing that is gone.
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.folder")
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text(message)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try Again", action: retry)
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
