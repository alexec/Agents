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
/// Read-only, as the Mac's is (FR-016). Nothing here can create, rename or delete.
struct FilesPane: View {
    @Environment(RemoteModel.self) private var model
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

    private var state: PaneState { model.panes.state(for: agent.id) }
    private var folder: URL { state.folder ?? agent.cwd }
    private var isAtTop: Bool { folder.standardizedFileURL == agent.cwd.standardizedFileURL }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            bar
            Divider()
            if let file = state.openFile {
                fileView(file)
            } else {
                listingView
            }
        }
        .task { await start() }
        .task(id: folder) { await relist() }
        .task(id: state.openFile) { await reopen() }
        .onChange(of: model.files.changeCount(agentID: agent.id, folder: folder)) {
            Task { await relist(inBackground: true) }
        }
        .onChange(of: state.openFile.map { model.files.changeCount(agentID: agent.id, folder: $0.deletingLastPathComponent()) }) {
            Task { await reopen(inBackground: true) }
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
            } else if !isAtTop {
                Button {
                    state.folder = folder.deletingLastPathComponent()
                } label: {
                    Label("Up", systemImage: "chevron.up").labelStyle(.iconOnly)
                }
                .accessibilityHint("Up one folder")
            }
            Text(state.openFile?.lastPathComponent ?? folder.lastPathComponent)
                .appText(.reading).fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
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

    // MARK: The folder

    @ViewBuilder
    private var listingView: some View {
        switch listed {
        case .reading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .problem(let message):
            Said(message: message, symbol: "questionmark.folder")
        case .listing(let listing):
            let touched = model.touchedPaths(for: agent.id)
            List {
                ForEach(listing.entries) { entry in
                    row(entry, touched: touched.contains(entry.url))
                        .paperListRow()
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
        }
    }

    private func row(_ entry: DirectoryEntry, touched: Bool) -> some View {
        Button {
            if entry.isDirectory {
                state.folder = entry.url
            } else {
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
                if touched {
                    // The Mac's mark for "the agent changed this": the tint, as a dot.
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

    // MARK: One file

    @ViewBuilder
    private func fileView(_ url: URL) -> some View {
        switch opened {
        case .reading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .problem(let message):
            Said(message: message, symbol: "doc.questionmark")
        case .other(let description):
            Said(message: "\(description). It can't be shown here.", symbol: "doc")
        case .image(let box, let describedAs, _):
            Picture(image: box.image, description: describedAs)
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
                // The line at the top, kept on the pane for when it is drawn again.
                FileLines(text: text, line: state.openLine,
                          place: Binding(get: { state.scrollAnchor[url.path] },
                                         set: { state.scrollAnchor[url.path] = $0 }),
                          path: url.path)
            }
        }
    }

    // MARK: Reading

    private func start() async {
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
