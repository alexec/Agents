import AgentsKit
import SwiftUI

/// The agent's folder, and what is in it.
///
/// Read-only, deliberately (004 FR-017), with one exception that 022 made: a Markdown
/// file opens as a live page the person can type on, and what they type goes to disk
/// through the daemon. Nothing else here creates, renames, deletes or edits; the
/// terminal pane is still the escape hatch for the rest.
struct FilesPane: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let state: AgentPaneState

    @State private var listing: DirectoryListing?
    @State private var problem: String?
    @State private var probe: FileProbe?
    @State private var fileProblem: String?
    @State private var watch: FolderWatch?
    @State private var touched = TouchedPaths()
    /// How much of the page `touched` has folded, and which page: entries past
    /// `touchedThrough` are new and are folded in, and a page that was replaced or
    /// grown at the front is folded again from the top.
    @State private var touchedThrough = 0
    @State private var touchedPageStart = 0
    /// Which re-listing is the current one, so a slower earlier read landing after a
    /// later one does not put the older listing on screen.
    @State private var listingRequest = 0
    /// The file `probe` was read from, so a file opened from elsewhere is loaded once
    /// and not once for every pass.
    @State private var loaded: URL?
    /// Counted up on every folder event and handed to the page, which re-reads its
    /// pictures' stamps on each: a redrawn image changes no text (022 FR-020).
    @State private var folderEvents = 0

    private var folder: URL { state.folder ?? agent.cwd }

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
        .onDisappear { watch?.stop(); watch = nil }
        .onChange(of: model.entries.count) { refreshTouched() }
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
            } else if folder != agent.cwd {
                Button {
                    open(folder: folder.deletingLastPathComponent())
                } label: {
                    Label("Up", systemImage: "chevron.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }

            Text(state.openFile?.lastPathComponent ?? folder.lastPathComponent)
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
        if let problem {
            Gone(message: problem)
        } else if let listing {
            List {
                ForEach(listing.entries) { entry in
                    row(entry)
                }
                if listing.isTruncated {
                    Text("\(listing.omitted) more, not shown")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ entry: DirectoryEntry) -> some View {
        Button {
            if entry.isDirectory {
                open(folder: entry.url)
            } else {
                open(file: entry.url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
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
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                         agentID: agent.id, folderEvent: folderEvents)
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
                    FileLines(text: probe.text ?? "", line: state.openLine)
                    if probe.isTruncated {
                        Divider()
                        Text("Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(probe.prefix.count), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(probe.size), countStyle: .file)).")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
            case .image(let description):
                ImageFile(url: url, probe: probe, description: description)
            case .binary(let description):
                // Its bytes are never shown (FR-014). What is shown is the way out.
                OpenElsewhere(url: url, description: description)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Doing

    private func start() async {
        refreshTouched()
        // Deliberately not `open(folder:)`, which clears the open file: the pane is
        // arriving, not being navigated. When the agent asked for a file the sidebar
        // was usually shut, so this is the first pass and the file it named is sitting
        // in `state` waiting to be read. Clearing it here showed the folder instead,
        // which looked like `show_file` having done nothing at all.
        state.folder = folder
        reloadListing()
        // Not `open(file:)` either, for the same reason at one remove: that treats the
        // file as the user's own choice and throws away the line the agent named.
        if let openFile = state.openFile { reloadFile(openFile) }
        startWatching()
    }

    private func startWatching() {
        watch?.stop()
        // The watch is on the agent's whole folder, but the pane only re-reads the
        // directory it is showing and the file it has open. FSEvents coalesces, so a
        // build writing thousands of files is a handful of events, not thousands.
        watch = FolderWatch(root: agent.cwd) { _ in
            Task { @MainActor in
                folderEvents += 1
                // Off the main actor: a folder of thousands of entries is thousands
                // of stat calls, and a build writing beside the pane fires this
                // every fifth of a second.
                reloadListing(inBackground: true)
                if let openFile = state.openFile { reloadFile(openFile) }
            }
        }
    }

    private func open(folder url: URL) {
        state.folder = url
        state.openFile = nil
        state.openLine = nil
        probe = nil
        fileProblem = nil
        reloadListing()
    }

    private func open(file url: URL) {
        state.openFile = url
        // The user's own choice of file starts at the top. A line is where an agent
        // asked them to look, and that is only true of the file the agent named.
        state.openLine = nil
        reloadFile(url)
    }

    /// Read the folder now, or — for a change the disk reported rather than one the
    /// person made — on another thread, with the old listing kept up until the new
    /// one is in hand. Opening a folder stays on this thread so it appears in the
    /// same frame as the click.
    private func reloadListing(inBackground: Bool = false) {
        listingRequest += 1
        guard inBackground else {
            show(Result { try DirectoryReader.read(folder) }, of: folder)
            return
        }
        let folder = folder
        let request = listingRequest
        Task {
            let read = await Task.detached(priority: .userInitiated) {
                Result { try DirectoryReader.read(folder) }
            }.value
            // The pane moved on — to another folder, or to a later read — while this
            // one was reading.
            guard request == listingRequest else { return }
            show(read, of: folder)
        }
    }

    private func show(_ read: Result<DirectoryListing, any Error>, of folder: URL) {
        switch read {
        case .success(let fresh):
            listing = fresh
            problem = nil
        case .failure(DirectoryReader.Failure.gone):
            // Never leave contents on screen that cannot be vouched for (FR-016).
            listing = nil
            problem = "\(folder.lastPathComponent) is not there any more."
        case .failure(DirectoryReader.Failure.notReadable):
            listing = nil
            problem = "\(folder.lastPathComponent) cannot be opened."
        case .failure:
            listing = nil
            problem = "\(folder.lastPathComponent) could not be read."
        }
    }

    private func reloadFile(_ url: URL) {
        loaded = url
        do {
            let fresh = try FileProbe.read(url)
            // The watch is on the whole folder, so a build writing beside this file
            // lands here too. Unchanged bytes are not news: the page would diff two
            // equal texts and find nothing, but it need not be asked to.
            if let probe, probe.prefix == fresh.prefix, probe.size == fresh.size {
                fileProblem = nil
                return
            }
            probe = fresh
            fileProblem = nil
        } catch FileProbe.Failure.gone {
            // A Markdown page keeps what it last had (022); source has nothing to
            // keep that the listing does not say better.
            if !isMarkdown(url) { probe = nil }
            fileProblem = "\(url.lastPathComponent) is not there any more."
        } catch FileProbe.Failure.notReadable {
            probe = nil
            fileProblem = "\(url.lastPathComponent) cannot be read."
        } catch {
            probe = nil
            fileProblem = "\(url.lastPathComponent) could not be read."
        }
    }

    /// The kit's list, so the daemon's idea of a page and the pane's are one.
    private func isMarkdown(_ url: URL) -> Bool { ShownFile.isMarkdown(url) }

    /// Folded from the transcript the window is holding.
    ///
    /// Entries that arrived since the last fold are folded in; a page replaced, or
    /// grown at the front by an earlier page, is folded again from the top. Folding
    /// the whole page for every chunk resolved every path the agent had touched
    /// against the disk again, several times a second, while the agent talked.
    private func refreshTouched() {
        let entries = model.entries
        let pageStart = model.work.firstEntryIndex
        if pageStart == touchedPageStart, entries.count >= touchedThrough {
            for entry in entries[touchedThrough...] { touched.absorb(entry) }
        } else {
            touched = TouchedPaths(entries: entries)
        }
        touchedThrough = entries.count
        touchedPageStart = pageStart
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
