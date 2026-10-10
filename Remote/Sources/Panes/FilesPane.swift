import AgentsKitCore
import SwiftUI

/// Files: the agent's folder as it is on the Mac now, read on the phone (034).
///
/// The Mac's files pane, reached through the daemon. It starts at the folder the agent
/// works in (its worktree, when it has one), lists folders first with the files the agent
/// changed marked as on the Mac, and reads a file as it is on disk rather than as the
/// conversation remembers it. A Markdown file goes to the Page. What the agent did to a
/// file stays one tap away.
///
/// On a regular-width iPad the folder is a tree, as the window's is: folders open in
/// place and stay open (#345). A phone's width has no room for the indents, so the
/// phone keeps one folder at a time, as the page does below 760 points.
///
/// Read-only, as the Mac's is (FR-016), but for a text file's source, which can be typed
/// in (#415). Nothing here can create, rename or delete.
struct FilesPane: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass
    let agent: Agent

    private enum Listed: Equatable {
        case reading
        case listing(DirectoryListing)
        case problem(String)
    }

    private enum Opened: Equatable {
        case reading
        case text(String, isTruncated: Bool, size: Int, stamp: FileStamp)
        case image(UIImageBox, describedAs: String, stamp: FileStamp)
        case other(String)
        case problem(String)
    }

    @State private var listed = Listed.reading
    @State private var opened = Opened.reading
    @State private var generation = 0
    /// The file the person just chose from a row, which is in view already.
    @State private var chosenFromRow: URL?
    @State private var changeIndex = ChangeTree.Index()
    /// The tree's folders, read as the window reads its own (#345).
    @State private var reads = FileTreeReads()

    private var state: PaneState { model.panes.state(for: agent.id) }
    private var folder: URL { state.folder ?? agent.cwd }
    private var isAtTop: Bool { folder.standardizedFileURL == agent.cwd.standardizedFileURL }
    /// A tree on a regular-width iPad, a folder at a time on a phone.
    private var isTree: Bool { sizeClass == .regular }
    /// The top of the tree: the agent's folder, with whatever was asked for inside it
    /// opened down to; or, for something outside it, that folder on its own.
    private var root: URL { FileTree.isInside(folder, agent.cwd) ? agent.cwd : folder }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            bar
            Divider()
            // The folder stays under an open file rather than going, so Back finds it
            // as it was left: scrolled where it was, the file's row marked (#66).
            ZStack {
                Group {
                    if isTree { treeView } else { listingView }
                }
                    .opacity(state.openFile == nil ? 1 : 0)
                    .allowsHitTesting(state.openFile == nil)
                    .accessibilityHidden(state.openFile != nil)
                if let file = state.openFile {
                    fileView(file)
                }
            }
        }
        .task {
            await start()
            // The folder is watched while the pane shows it, and let go when it goes (#175).
            await untilCancelled()
            await model.files.unwatch(agentID: agent.id, folder: agent.cwd)
        }
        .task(id: model.entries.count) { await refreshChangeIndex() }
        .onChange(of: state.openFile) { _, url in
            guard let url else { return }
            state.place.opened(url, fromRow: url == chosenFromRow)
            chosenFromRow = nil
            // In the tree, opened down to, so Back has it in view.
            if isTree {
                reveal(url.deletingLastPathComponent())
                readUnread()
            }
        }
        .task(id: Shown(isTree: isTree, folder: folder)) {
            if isTree {
                reveal(folder)
                readTree()
            } else {
                await relist()
            }
        }
        .task(id: state.openFile) { await reopen() }
        .onChange(of: model.files.changeCount(agentID: agent.id, folder: folder)) {
            guard !isTree else { return }
            Task { await relist(inBackground: true) }
        }
        // The tree shows more than one folder: anything changed under the agent's is
        // read again, as the window does.
        .onChange(of: model.files.anyChange[agent.id] ?? 0) {
            guard isTree else { return }
            readTree()
        }
        .onChange(of: state.openFile.map { model.files.changeCount(agentID: agent.id, folder: $0.deletingLastPathComponent()) }) {
            Task { await reopen(inBackground: true) }
        }
        // The Mac is back on a new connection: what is shown is read again, whichever
        // folder it is in, and a read that failed while it was gone gets another go (#62).
        .onChange(of: model.files.reconnections) {
            Task {
                if isTree { readTree() } else { await relist(inBackground: true) }
                await reopen(inBackground: true)
            }
        }
        .sheet(isPresented: $state.showingChanges) {
            if let file = state.openFile {
                NavigationStack {
                    ChangesView(path: file.path)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { state.showingChanges = false }
                            }
                        }
                }
                .paperSheet()
            }
        }
    }

    // MARK: The bar

    private var bar: some View {
        HStack(spacing: 8) {
            if state.openFile != nil {
                Button {
                    state.openFile = nil
                    state.openLine = nil
                } label: {
                    Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .accessibilityHint("Back to the folder")
            } else if isTree {
                // The tree opens folders in place: the only way up is out of a folder
                // outside the agent's, back to its own, as on the Mac.
                if root.standardizedFileURL != agent.cwd.standardizedFileURL {
                    Button {
                        state.folder = nil
                    } label: {
                        Label("The agent's folder", systemImage: "house").labelStyle(.iconOnly)
                    }
                }
            } else if !isAtTop {
                Button {
                    state.folder = folder.deletingLastPathComponent()
                } label: {
                    Label("Up", systemImage: "chevron.up").labelStyle(.iconOnly)
                }
                .accessibilityHint("Up one folder")
            }
            Text(state.openFile?.lastPathComponent ?? (isTree ? root : folder).lastPathComponent)
                .appText(.reading).fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if let file = state.openFile, canDrawPage(file) {
                pageControls(file)
            }
            if let file = state.openFile, PinRules.kind(file.path) == .html,
               let path = agent.pinPath(file.path) {
                pinButton(path)
            }
            if let file = state.openFile, !ChangesView.changes(to: file.path, in: model.entries).isEmpty {
                Button("What the agent did") { state.showingChanges = true }
                    .appText(.fine)
                    .buttonStyle(.paper)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// An HTML file's two ways of being read (#67), as on the Mac: the page or its
    /// source, one choice for the pane; and, on the page, whether it may run scripts.
    @ViewBuilder
    private func pageControls(_ url: URL) -> some View {
        @Bindable var state = state
        if !state.htmlShowsSource {
            Toggle(isOn: Binding(get: { state.scriptsAllowed.contains(url.path) },
                                 set: { allowed in
                                     if allowed { state.scriptsAllowed.insert(url.path) } else { state.scriptsAllowed.remove(url.path) }
                                 })) {
                Label("Allow scripts", systemImage: "curlybraces")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .accessibilityHint(state.scriptsAllowed.contains(url.path)
                               ? "Scripts run on this page, with no network"
                               : "Scripts are off on this page")
        }
        Picker("Show", selection: $state.htmlShowsSource) {
            Text("Page").tag(false)
            Text("Source").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// An HTML file read whole: one cut at the read limit is source only, never half a page.
    private func canDrawPage(_ url: URL) -> Bool {
        guard HTMLPageScope.isHTML(url), case .text(_, let isTruncated, _, _) = opened else { return false }
        return !isTruncated
    }

    /// Where a link the person tapped on a page goes. Never into the file view itself.
    private func follow(_ link: HTMLPageScope.LinkDecision) {
        switch link {
        case .openFile(let path): state.open(file: URL(filePath: path), line: nil)
        case .openOutside(let url): openURL(url)
        case .stay, .ignore: break
        }
    }

    // MARK: The folder

    @ViewBuilder
    private var listingView: some View {
        switch listed {
        case .reading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .problem(let message):
            Said(message: message, symbol: "questionmark.folder") { Task { await relist() } }
        case .listing(let listing):
            let touched = model.touchedPaths(for: agent.id)
            ScrollViewReader { reader in
                List {
                    ForEach(listing.entries) { entry in
                        let isMarked = !entry.isDirectory && state.place.marked == FileTree.key(entry.url)
                        row(entry, touched: touched.contains(entry.url),
                            changed: changeIndex.files[entry.url.path],
                            folderTotals: changeIndex.folders[entry.url.path])
                            // The file last open, so Back shows where it is (#66).
                            .listRowBackground(Paper.raised.overlay(isMarked ? Paper.accent.opacity(0.15) : .clear))
                            .accessibilityAddTraits(isMarked ? .isSelected : [])
                    }
                    if listing.isTruncated {
                        Text("\(listing.omitted) more, not shown")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .paperListRow()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear { bringMarkedIntoView(listing, reader) }
                .onChange(of: listing) { bringMarkedIntoView(listing, reader) }
                .onChange(of: state.place.toScroll) { bringMarkedIntoView(listing, reader) }
            }
        }
    }

    // MARK: The tree (#345)

    /// What the folder view is keyed on: a tree or a folder, and which.
    private struct Shown: Hashable {
        var isTree: Bool
        var folder: URL
    }

    /// The window's tree, on a regular-width iPad: each open folder's entries under it,
    /// one step in, drawn with the window's rows.
    @ViewBuilder
    private var treeView: some View {
        if let problem = reads.problems[FileTree.key(root)] {
            Said(message: problem, symbol: "questionmark.folder") { reads.read(root, agentID: agent.id, files: model.files) { readUnread() } }
        } else if reads.listings[FileTree.key(root)] != nil {
            let lines = reads.lines(root: root, expanded: state.expanded)
            let touched = model.touchedPaths(for: agent.id)
            ScrollViewReader { reader in
                List {
                    ForEach(lines) { line in
                        switch line {
                        case .entry(let entry, let depth):
                            treeRow(entry, depth: depth, touched: touched)
                        case .note(_, let words, let depth):
                            Text(words)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .padding(.leading, FileTreeRow.indent(depth))
                                .paperListRow()
                        case .problem(let folder, let words, let depth):
                            HStack(spacing: 8) {
                                Text(words)
                                    .appText(.fine)
                                    .foregroundStyle(.secondary)
                                Button("Try Again") {
                                    reads.read(folder, agentID: agent.id, files: model.files) { readUnread() }
                                }
                                .appText(.fine)
                                .buttonStyle(.borderless)
                            }
                            .padding(.leading, FileTreeRow.indent(depth))
                            .paperListRow()
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear { bringMarkedIntoView(lines, reader) }
                .onChange(of: lines.map(\.id)) { bringMarkedIntoView(lines, reader) }
                .onChange(of: state.place.toScroll) { bringMarkedIntoView(lines, reader) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func treeRow(_ entry: DirectoryEntry, depth: Int, touched: TouchedPaths) -> some View {
        let key = FileTree.key(entry.url)
        let isMarked = !entry.isDirectory && state.place.marked == key
        let changed = entry.isDirectory ? nil : changeIndex.files[entry.url.path]
        return FileTreeRow(entry: entry, depth: depth,
                           isOpen: entry.isDirectory && state.expanded.contains(key),
                           changed: changed, folderTotals: changeIndex.folders[entry.url.path],
                           touched: !entry.isDirectory && changed == nil && touched.contains(entry.url)) {
            if entry.isDirectory {
                toggle(folder: entry.url)
            } else {
                chosenFromRow = entry.url
                // A Markdown file goes to the Page, and Files is drawn again on return.
                state.place.opened(entry.url, fromRow: true)
                state.open(file: entry.url, line: nil)
            }
        }
        // The file last open, so Back shows where it is (#66).
        .listRowBackground(Paper.raised.overlay(isMarked ? Paper.accent.opacity(0.15) : .clear))
        .accessibilityAddTraits(isMarked ? .isSelected : [])
    }

    /// Scroll the marked file's row into view, once its folder has been read.
    private func bringMarkedIntoView(_ lines: [FileTree.Line], _ reader: ScrollViewProxy) {
        guard state.place.toScroll != nil else { return }
        var rows: [String: String] = [:]
        for line in lines {
            if case .entry(let entry, _) = line, !entry.isDirectory { rows[FileTree.key(entry.url)] = line.id }
        }
        guard let key = state.place.scroll(among: rows.keys), let id = rows[key] else { return }
        // After this pass: a list that has only just appeared has not been laid out.
        Task { reader.scrollTo(id, anchor: .center) }
    }

    /// Open a folder in place, or close it. Opening reads it again even when it was
    /// read before: what it held then may not be what it holds now.
    private func toggle(folder url: URL) {
        let key = FileTree.key(url)
        if state.expanded.contains(key) {
            state.expanded.remove(key)
        } else {
            state.expanded.insert(key)
            reads.read(url, agentID: agent.id, files: model.files) { readUnread() }
        }
    }

    /// Open every folder between the agent's and the one asked for.
    private func reveal(_ folder: URL) {
        state.expanded.formUnion(FileTree.opening(to: folder, from: agent.cwd))
    }

    /// Every folder on screen, read again; the listings up stay until the new ones are in.
    private func readTree() {
        for folder in reads.visibleFolders(root: root, expanded: state.expanded) {
            reads.read(folder, agentID: agent.id, files: model.files) { readUnread() }
        }
    }

    /// Every open folder on screen with nothing to show and no read on its way (#62).
    private func readUnread() {
        for folder in reads.unread(root: root, expanded: state.expanded) {
            reads.read(folder, agentID: agent.id, files: model.files) { readUnread() }
        }
    }

    /// Scroll the marked file's row into view, once it is in the folder on screen.
    private func bringMarkedIntoView(_ listing: DirectoryListing, _ reader: ScrollViewProxy) {
        guard state.place.toScroll != nil else { return }
        var rows: [String: URL] = [:]
        for entry in listing.entries where !entry.isDirectory { rows[FileTree.key(entry.url)] = entry.id }
        guard let key = state.place.scroll(among: rows.keys), let id = rows[key] else { return }
        // After this pass: a list that has only just appeared has not been laid out.
        Task { reader.scrollTo(id, anchor: .center) }
    }

    private func row(_ entry: DirectoryEntry, touched: Bool, changed: ChangedFile?,
                     folderTotals: ChangeTree.Totals?) -> some View {
        Button {
            if entry.isDirectory {
                state.folder = entry.url
            } else {
                chosenFromRow = entry.url
                // A Markdown file goes to the Page, and Files is drawn again on return.
                state.place.opened(entry.url, fromRow: true)
                state.open(file: entry.url, line: nil)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let changed {
                    Image(systemName: ChangeTint.symbol(changed.state))
                        .foregroundStyle(ChangeTint.color(changed.state))
                        .accessibilityLabel(ChangeWords.status(changed.state))
                    if let added = changed.added, let removed = changed.removed {
                        Text("+\(added) −\(removed)").appText(.fine).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else if entry.isDirectory, let folderTotals {
                    Text("+\(folderTotals.added) −\(folderTotals.removed)")
                        .appText(.fine).monospacedDigit().foregroundStyle(.secondary)
                } else if touched {
                    // Older transcripts may know a touched path before the git list does.
                    Circle().fill(.tint).frame(width: 7, height: 7)
                        .accessibilityLabel("Changed by the agent")
                }
                if entry.isDirectory {
                    Image(systemName: "chevron.right").appText(.fine).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func refreshChangeIndex() async {
        guard let list = try? await model.changes(for: agent.id) else { return }
        changeIndex = ChangeTree.Index(list.files)
    }

    @ViewBuilder
    private func pinButton(_ path: String) -> some View {
        let pinned = model.pins(in: agent.projectFolder).contains { $0.path == path }
        Button(pinned ? "Unpin" : "Pin") {
            Task {
                if pinned { await model.unpin(path, in: agent.projectFolder) }
                else { await model.pin(path, in: agent.projectFolder) }
            }
        }
        .appText(.fine)
        .buttonStyle(.paper)
        .disabled(!pinned && model.pins(in: agent.projectFolder).count >= PinLimits.perProject)
    }

    // MARK: One file

    @ViewBuilder
    private func fileView(_ url: URL) -> some View {
        switch opened {
        case .reading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .problem(let message):
            Said(message: message, symbol: "doc.questionmark") { Task { await reopen() } }
        case .other(let description):
            Said(message: "\(description). It can't be shown here.", symbol: "doc")
        case .image(let box, let describedAs, _):
            Picture(image: box.image, description: describedAs)
        case .text(let text, _, _, _) where canDrawPage(url) && !state.htmlShowsSource:
            // HTML reads as a page (#67), reloaded in place as the file or anything
            // beside it changes. What the page may do is decided in `HTMLPage`.
            let files = model.files
            let agentID = agent.id
            HTMLPage(text: text, path: url.path,
                     scope: HTMLPageScope(file: url, agentFolder: agent.cwd),
                     allowsScripts: state.scriptsAllowed.contains(url.path),
                     folderEvent: files.anyChange[agent.id] ?? 0,
                     read: { try await files.read(agentID: agentID, path: $0) },
                     follow: follow)
        case .text(let text, let isTruncated, let size, _):
            VStack(spacing: 0) {
                if isTruncated {
                    Text(FileReading.truncationNote(shown: text.utf8.count, of: size))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                }
                if isTruncated {
                    // The line at the top, kept on the pane for when it is drawn again.
                    // Only partly read, so not typed in: saving it would cut it short.
                    FileLines(text: text, line: state.openLine,
                              place: Binding(get: { state.scrollAnchor[url.path] },
                                             set: { state.scrollAnchor[url.path] = $0 }),
                              path: url.path)
                } else {
                    // Its source, to type in, saved on the Mac as a page is (#415).
                    SourceEditor(text: text, path: url.path, line: state.openLine)
                        .id(url)
                        .environment(\.pageActions, editActions)
                }
            }
        }
    }

    /// A source file's saves go to the Mac; nothing is typed while it is not answering.
    private var editActions: PageActions {
        let agentID = agent.id
        let model = model
        return PageActions(
            save: { path, document in await model.writeArtifact(agentID: agentID, path: path, text: document) },
            canEdit: !model.isStale)
    }

    // MARK: Reading

    private func start() async {
        // A list drawn new starts at the top: the file open, or last open, is found again.
        if let file = state.openFile { state.place.opened(file, fromRow: false) } else { state.place.drawnAfresh() }
        // In the tree, the file open is found with its folders open (#345).
        if isTree, let file = state.openFile { reveal(file.deletingLastPathComponent()) }
        await model.files.watch(agentID: agent.id, folder: agent.cwd)
        await model.loadTouchedHistory(for: agent.id)
    }

    /// Read the folder. A change the Mac reported keeps the old listing up until the
    /// new one is in hand; a folder opened by the person shows it is reading.
    private func relist(inBackground: Bool = false) async {
        generation += 1
        let mine = generation
        let folder = folder
        if !inBackground { listed = .reading }
        do {
            let listing = try await model.files.list(agentID: agent.id, folder: folder)
            guard mine == generation else { return }
            listed = .listing(listing)
        } catch {
            guard mine == generation else { return }
            // Never leave a listing on screen that cannot be vouched for (FR-017),
            // unless it is only that the Mac has gone quiet, which the banner says.
            if model.isStale, case .listing = listed { return }
            listed = .problem(RemoteFiles.isGone(error) && isAtTop
                              ? "This agent's folder is gone."
                              : RemoteFiles.describe(error, name: folder.lastPathComponent))
        }
    }

    private func reopen(inBackground: Bool = false) async {
        guard let url = state.openFile else { return }
        var known: FileStamp?
        if inBackground {
            switch opened {
            case .text(_, _, _, let stamp), .image(_, _, let stamp): known = stamp
            default: break
            }
        } else {
            opened = .reading
        }
        do {
            let reading = try await model.files.read(agentID: agent.id, path: url.path, known: known)
            guard state.openFile == url else { return }
            switch reading {
            case .unchanged:
                break
            case .text(let text, let isTruncated, let size, let stamp):
                opened = .text(text, isTruncated: isTruncated, size: size, stamp: stamp)
            case .image(let bytes, let describedAs, let stamp):
                let image = await model.pictures.image(agentID: agent.id, url: url)
                    ?? UIImage(data: bytes)
                opened = image.map { .image(UIImageBox(image: $0), describedAs: describedAs, stamp: stamp) }
                    ?? .other(describedAs)
            case .other(let describedAs, _, _):
                opened = .other(describedAs)
            }
        } catch {
            guard state.openFile == url else { return }
            if model.isStale, inBackground { return }
            opened = .problem(RemoteFiles.describe(error, name: url.lastPathComponent))
        }
    }
}

/// A picture, fitted, and pinched to look closer: pinch to zoom, drag to move about,
/// double-tap to go between fitted and close up at the place tapped.
///
/// UIKit's own zooming scroll view rather than a SwiftUI scale: a scale effect leaves
/// the layout the size it was, so a zoomed picture could not be dragged to its edges,
/// which are the details a screenshot is zoomed into to read.
private struct Picture: UIViewRepresentable {
    let image: UIImage
    let description: String

    func makeUIView(context: Context) -> ZoomingPictureView {
        let view = ZoomingPictureView()
        view.show(image)
        view.imageView.accessibilityLabel = description
        return view
    }

    func updateUIView(_ view: ZoomingPictureView, context: Context) {
        view.imageView.accessibilityLabel = description
        if view.imageView.image !== image { view.show(image) }
    }
}

final class ZoomingPictureView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    /// Most a picture is blown up past its own size. Past this a screenshot is squares.
    private static let most: CGFloat = 8
    /// Whether to refit as the pane changes size, as it does when the phone turns.
    /// Cleared by any zoom but back to fitted.
    private var fitted = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        bouncesZoom = true
        showsHorizontalScrollIndicator = true
        showsVerticalScrollIndicator = true
        contentInsetAdjustmentBehavior = .never
        imageView.isAccessibilityElement = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws a new picture, fitted. A rewrite of the file is a new picture, and where
    /// the reader was in the old one says nothing about the new one.
    func show(_ image: UIImage) {
        zoomScale = 1
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size
        fitted = true
        setNeedsLayout()
    }

    /// The scale that shows the whole picture, never more than its own size: a
    /// 48-point icon blown up to fill the pane is not a preview of the icon.
    private var fitScale: CGFloat {
        let size = imageView.image?.size ?? .zero
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(1, bounds.width / size.width, bounds.height / size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        minimumZoomScale = fitScale
        maximumZoomScale = max(Self.most, fitScale)
        if fitted, abs(zoomScale - fitScale) > 0.0001 { zoomScale = fitScale }
        centre()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        fitted = abs(scale - fitScale) < 0.0001
    }

    /// Keeps a picture smaller than the pane in the middle of it rather than the corner.
    private func centre() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if fitted {
            // To the picture's own size; one that already fits at its own size would
            // not move, so twice it instead.
            let scale: CGFloat = fitScale < 1 ? 1 : 2
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        } else {
            setZoomScale(fitScale, animated: true)
        }
    }
}

/// A sentence in place of what could not be shown.
private struct Said: View {
    let message: String
    let symbol: String
    /// Try Again, for a read that failed.
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .appText(.title)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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

/// A picture held in state. `UIImage` is not `Equatable` by content, and the pane only
/// needs to know it was replaced.
struct UIImageBox: Equatable {
    let image: UIImage
    static func == (lhs: UIImageBox, rhs: UIImageBox) -> Bool { lhs.image === rhs.image }
}

extension Agent {
    /// A file's path in the project, as a pin names it (#536): from a worktree, the same
    /// path in the project folder, where the pin opens it, as on the Mac and the web.
    func pinPath(_ file: String) -> String? {
        PinRules.relative(file, in: worktree != nil ? cwd : projectFolder)
    }
}
