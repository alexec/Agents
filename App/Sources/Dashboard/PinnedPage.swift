import AgentsKitCore
import AppKit
import SwiftUI

/// A project's pinned page (#159), open in the chat's place: the live page the files pane
/// shows for `show_file`, read from the project folder through its host rather than
/// through an agent. Markdown follows the file and takes typing; HTML is drawn with
/// scripts and the network off, with Page and Source.
struct PinnedPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let project: ProjectKey
    let path: String

    @State private var text: String?
    @State private var stamp: FileStamp?
    /// Which page `text` and `stamp` are of: another page's stamp would read as unchanged.
    @State private var loadedPath: String?
    @State private var problem: String?
    @State private var showsSource = false
    @State private var pictures: PagePictures?

    private var pin: PinView? { model.pins(in: project.folder).first { $0.path == path } }
    private var kind: PinKind { PinRules.kind(path) ?? .markdown }
    private var url: URL { project.folder.appending(path: path) }
    private var revision: Int { model.pageRevision(in: project.folder) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(path)|\(revision)|\(pin?.missing == true)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind == .html ? "globe" : "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(pin?.title ?? PinRules.defaultTitle(path))
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)
                Text(path)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if kind == .html {
                Picker("Show", selection: $showsSource) {
                    Text("Page").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if model.isOnThisMac(project.host) {
                Button("Show in Finder") { model.reveal(url, on: project.host) }
                    .buttonStyle(.paper)
                    .disabled(problem != nil)
            }
            if pin != nil {
                Button("Unpin") { Task { await model.unpin(path, in: project) } }
                    .buttonStyle(.paper)
            } else {
                // Opened from a page tile, and not pinned yet.
                Button("Pin to Project") { Task { await model.pin(path, in: project) } }
                    .buttonStyle(.paper)
                    .disabled(model.pins(in: project.folder).count >= PinLimits.perProject || problem != nil)
                    .help(model.pins(in: project.folder).count >= PinLimits.perProject
                          ? "This project already has \(PinLimits.perProject) pinned pages, the most it can have."
                          : "Pin this page under the project in the sidebar.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let problem {
            VStack(spacing: 10) {
                Image(systemName: "doc.questionmark")
                    .appText(.title)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(problem)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if pin != nil {
                    Button("Unpin") { Task { await model.unpin(path, in: project) } }
                        .buttonStyle(.paper)
                }
            }
            .padding(24)
        } else if let text, loadedPath == path {
            switch kind {
            case .markdown, .view:
                LivePage(text: text, url: url, line: nil, folderEvent: revision)
                    .environment(\.pageActions, actions)
            case .html where showsSource:
                ScrollView {
                    Text(text)
                        .appText(.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            case .html:
                HTMLPage(text: text, path: url.path(percentEncoded: false),
                         scope: HTMLPageScope(root: project.folder.path(percentEncoded: false)),
                         allowsScripts: false, folderEvent: revision,
                         read: { [model, project] file in try await model.readPage(file, in: project) },
                         follow: follow)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var actions: PageActions {
        let pictures = pictures ?? PagePictures(model: model, project: project)
        return PageActions(
            save: { [model, project, path] _, document in await model.writePage(path, in: project, text: document) },
            image: { url in await pictures.image(url) },
            stamp: { url in await pictures.stamp(url) },
            canEdit: !model.hostUnreachable(project.host))
    }

    private func load() async {
        if pictures == nil { pictures = PagePictures(model: model, project: project) }
        do {
            let reading = path
            switch try await model.readPage(reading, in: project, known: loadedPath == reading ? stamp : nil) {
            case .text(let read, _, _, let at):
                text = read
                stamp = at
                loadedPath = reading
                problem = nil
            case .unchanged:
                problem = nil
            case .image, .other:
                problem = "\(path) can't be shown as a page."
            }
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.fileGone {
            problem = "\(path) isn't in the project folder. It may have been moved or deleted, "
                + "or be on a branch that hasn't landed."
            stamp = nil
        } catch {
            problem = "\(path) can't be read: \((error as? JSONRPCError)?.message ?? error.localizedDescription)"
        }
    }

    private func follow(_ link: HTMLPageScope.LinkDecision) {
        switch link {
        case .openFile(let file):
            // Another of the project's pinned pages opens in its place; anything else is
            // the project's, not this page's, to show.
            if let relative = PinRules.relative(file, in: project.folder),
               model.pins(in: project.folder).contains(where: { $0.path == relative }) {
                model.showPin(relative, in: project)
            }
        case .openOutside(let url):
            openURL(url)
        case .stay, .ignore:
            break
        }
    }
}

/// The pictures beside a pinned page, read through the project's host and kept with the
/// stamp they were read at, as `ServerPictures` keeps an agent's.
@MainActor
final class PagePictures {
    private struct Held {
        var stamp: FileStamp
        var image: NSImage?
    }

    private let model: AppModel
    private let project: ProjectKey
    /// About a page or two of diagrams, as the phone keeps (#175, #213).
    private var held = LRUCache<URL, Held>(limit: 24)

    init(model: AppModel, project: ProjectKey) {
        self.model = model
        self.project = project
    }

    func stamp(_ url: URL) async -> FileStamp? { await refresh(url)?.stamp }

    func image(_ url: URL) async -> NSImage? {
        if let image = held.value(for: url)?.image { return image }
        return await refresh(url)?.image
    }

    private func refresh(_ url: URL) async -> Held? {
        let known = held.peek(url)
        guard let reading = try? await model.readPage(url.path(percentEncoded: false), in: project,
                                                      known: known?.stamp) else { return known }
        switch reading {
        case .unchanged:
            return known
        case .image(let bytes, _, let stamp):
            let fresh = Held(stamp: stamp, image: NSImage(data: bytes))
            held.set(fresh, for: url)
            return fresh
        case .text(_, _, _, let stamp), .other(_, _, let stamp):
            let fresh = Held(stamp: stamp, image: nil)
            held.set(fresh, for: url)
            return fresh
        }
    }
}

/// A page tile's page (#159): the project's document or HTML page drawn live on the
/// Dashboard, read-only, the top of it, with Open for the whole of it in the chat's place.
struct PageTileBody: View {
    @Environment(AppModel.self) private var model
    let project: ProjectKey
    let file: String

    @State private var text: String?
    @State private var stamp: FileStamp?
    @State private var problem: String?

    /// As tall as a third of a typical window: enough to read, not so much that it buries
    /// the tiles under it.
    static let height: CGFloat = 300

    private var url: URL { project.folder.appending(path: file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let text {
                    if PinRules.kind(file) == .html {
                        HTMLPage(text: text, path: url.path(percentEncoded: false),
                                 scope: HTMLPageScope(root: project.folder.path(percentEncoded: false)),
                                 allowsScripts: false, folderEvent: model.pageRevision(in: project.folder),
                                 read: { [model, project] path in try await model.readPage(path, in: project) },
                                 follow: { _ in })
                    } else {
                        // Read-only, as a note is: a live page that can't be typed on draws
                        // its passages as disabled controls, greyed.
                        MarkdownText(markdown: text, base: url)
                            .appText(.supporting)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: problem == nil ? Self.height : nil,
                   maxHeight: problem == nil ? Self.height : nil, alignment: .top)
            .clipped()
            HStack {
                Text(file)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open") { model.showPin(file, in: project) }
                    .buttonStyle(.link)
                    .appText(.fine)
            }
        }
        .task(id: model.pageRevision(in: project.folder)) { await load() }
    }

    private func load() async {
        do {
            switch try await model.readPage(file, in: project, known: stamp) {
            case .text(let read, _, _, let at):
                text = read
                stamp = at
                problem = nil
            case .unchanged:
                break
            case .image, .other:
                problem = "\(file) can't be shown as a page."
            }
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.fileGone {
            problem = "\(file) isn't in the project folder."
            stamp = nil
        } catch {
            problem = "\(file) can't be read."
        }
    }
}
