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
    let agent: Agent
    let state: AgentPaneState

    /// Every folder read so far, by path: the top, and each one opened in the tree.
    @State private var listings: [String: DirectoryListing] = [:]
    @State private var problems: [String: String] = [:]
    @State private var probe: FileProbe?
    @State private var fileProblem: String?
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
    /// The file `probe` was read from, so a file opened from elsewhere is loaded once
    /// and not once for every pass.
    @State private var loaded: URL?
    /// Counted up on every folder event and handed to the page, which re-reads its
    /// pictures' stamps on each: a redrawn image changes no text (022 FR-020).
    @State private var folderEvents = 0

    private var folder: URL { state.folder ?? agent.cwd }

    /// The top of the tree: the agent's folder, with whatever was asked for inside it
    /// opened down to; or, for something outside it, that folder on its own.
    private var root: URL { Self.isInside(folder, agent.cwd) ? agent.cwd : folder }

    /// Every host's folder is read through that host (037), this Mac's included (058, R11).
    private var server: RemoteFiles { model.serverFiles(agent.host) }
    /// Where a file the pane will not draw is, when Finder here cannot show it: nil for
    /// this Mac's host, whose files the window reveals and opens through it.
    private var elsewhere: String? { model.isOnThisMac(agent.host) ? nil : model.hosts.label(agent.host) }
    private var serverChanges: Int { server.changeCount(agentID: agent.id, folder: folder) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let openFile = state.openFile {
                fileView(openFile)
            } else {
                listingView
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
            reloadListings(inBackground: true)
            if let openFile = state.openFile { reloadFile(openFile) }
        }
        .onChange(of: model.entries.count) { refreshTouched() }
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
            loaded = nil
            probe = nil
            listings = [:]
            problems = [:]
            reloadListings()
            startWatching()
        }
        // A file opened from elsewhere — the chat, a permission card — names its folder,
        // and the tree opens down to it so Back finds it in place.
        .onChange(of: state.folder) {
            reveal()
            reloadListings()
        }
        // The agent can open a file here as well as the user (`show_file`), and when
        // it does, this pane is already on screen and has already run its task.
        .onChange(of: state.openFile) { _, url in
            guard let url, url != loaded else { return }
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: The folder

    @ViewBuilder
    private var listingView: some View {
        if let problem = problems[Self.key(root)] {
            Gone(message: problem)
        } else if listings[Self.key(root)] != nil {
            List {
                ForEach(treeLines) { line in
                    switch line {
                    case .entry(let entry, let depth):
                        row(entry, depth: depth)
                    case .note(_, let words, let depth):
                        Text(words)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .padding(.leading, indent(depth))
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One line of the tree, as the list draws it.
    private enum TreeLine: Identifiable {
        case entry(DirectoryEntry, depth: Int)
        case note(id: String, String, depth: Int)

        var id: String {
            switch self {
            case .entry(let entry, _): entry.url.absoluteString
            case .note(let id, _, _): id
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
                lines.append(.note(id: "problem:\(key)", problem, depth: depth))
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
        var folders = [root]
        func add(_ folder: URL) {
            for entry in listings[Self.key(folder)]?.entries ?? []
            where entry.isDirectory && state.expanded.contains(Self.key(entry.url)) {
                folders.append(entry.url)
                add(entry.url)
            }
        }
        add(root)
        return folders
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(depth) * 14 }

    private func row(_ entry: DirectoryEntry, depth: Int) -> some View {
        let isOpen = entry.isDirectory && state.expanded.contains(Self.key(entry.url))
        return Button {
            if entry.isDirectory {
                toggle(folder: entry.url)
            } else {
                open(file: entry.url)
            }
        } label: {
            HStack(spacing: 6) {
                // The same width for a file as a folder's chevron, so names line up.
                Image(systemName: "chevron.right")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .opacity(entry.isDirectory ? 1 : 0)
                    .frame(width: 10)
                Image(systemName: entry.isDirectory ? (isOpen ? "folder.fill" : "folder") : "doc")
                    .foregroundStyle(entry.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if touched.contains(entry.url) {
                    // What the agent touched since it started (FR-013). The point of
                    // the pane: its work is findable without reading the conversation.
                    Image(systemName: "circle.fill")
                        // Decorative: a dot sized to the row, not text (FR-015).
                        .font(.system(size: 6))
                        .foregroundStyle(.tint)
                        .help("The agent changed this")
                }
                Spacer()
            }
            .padding(.leading, indent(depth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(entry.isDirectory ? (isOpen ? "Expanded" : "Collapsed") : "")
    }

    // MARK: One file

    @ViewBuilder
    private func fileView(_ url: URL) -> some View {
        if isMarkdown(url), fileProblem != nil || probe?.kind.isText == true {
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
        } else if let fileProblem {
            Gone(message: fileProblem)
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
        reveal()
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
    private func reveal() {
        let top = Self.key(agent.cwd), target = Self.key(folder)
        guard target != top, target.hasPrefix(top + "/") else { return }
        var url = agent.cwd
        for part in target.dropFirst(top.count + 1).split(separator: "/") {
            url = url.appending(path: String(part), directoryHint: .isDirectory)
            state.expanded.insert(Self.key(url))
        }
    }

    /// A path as the tree keys it: no trailing slash, whichever way the URL was made.
    private static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

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
        let server = server
        let agentID = agent.id
        Task {
            let read: Result<DirectoryListing, any Error>
            do { read = .success(try await server.list(agentID: agentID, folder: folder)) }
            catch { read = .failure(error) }
            guard request == listingRequests[key] else { return }
            if case .failure(let error) = read {
                listings[key] = nil
                problems[key] = RemoteFiles.describe(error, name: folder.lastPathComponent)
            } else {
                show(read, of: folder)
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
        let server = server
        let agentID = agent.id
        Task {
            do {
                let reading = try await server.read(agentID: agentID, path: url.path(percentEncoded: false))
                guard let fresh = Self.probe(reading) else { return }
                // The watch is on the whole folder, so a build writing beside this file
                // lands here too. Unchanged bytes are not news.
                if let probe, probe.prefix == fresh.prefix, probe.size == fresh.size { fileProblem = nil; return }
                probe = fresh
                fileProblem = nil
            } catch {
                // A Markdown page keeps what it last had (022); source has nothing to
                // keep that the listing does not say better.
                if !(RemoteFiles.isGone(error) && isMarkdown(url)) { probe = nil }
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

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.folder")
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text(message)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
