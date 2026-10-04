import AgentsKitCore
import SwiftUI
import UIKit

/// A pinned page, pushed over the project page: the live page an agent's files show,
/// read from the project folder through the Mac. Markdown follows the file and takes
/// typing; HTML is drawn with scripts and the network off.
struct PinnedPage: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL
    let folder: URL
    let path: String

    @State private var text: String?
    @State private var stamp: FileStamp?
    @State private var problem: String?
    @State private var pictures: PhonePagePictures?

    private var pin: PinView? { model.pins(in: folder).first { $0.path == path } }
    private var url: URL { folder.appending(path: path) }
    private var revision: Int { model.work.pageRevision(in: folder) }

    var body: some View {
        Group {
            if let problem {
                ContentUnavailableView {
                    Label("Not in the project", systemImage: "doc.questionmark")
                } description: {
                    Text(problem)
                } actions: {
                    if pin != nil {
                        Button("Unpin") { Task { await model.unpin(path, in: folder) } }
                    }
                }
            } else if let text {
                if PinRules.kind(path) == .html {
                    HTMLPage(text: text, path: url.path(percentEncoded: false),
                             scope: HTMLPageScope(root: folder.path(percentEncoded: false)),
                             allowsScripts: false, folderEvent: revision,
                             read: { [model, folder] file in try await model.readPage(file, in: folder) },
                             follow: { link in if case .openOutside(let url) = link { openURL(url) } })
                } else {
                    LivePage(text: text, url: url, line: nil, folderEvent: revision)
                        .environment(\.pageActions, actions)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(pin?.title ?? PinRules.defaultTitle(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if pin != nil {
                    Button("Unpin", systemImage: "pin.slash") { Task { await model.unpin(path, in: folder) } }
                } else {
                    Button("Pin to Project", systemImage: "pin") { Task { await model.pin(path, in: folder) } }
                        .disabled(model.pins(in: folder).count >= PinLimits.perProject || problem != nil)
                }
            }
        }
        .task(id: "\(path)|\(revision)|\(pin?.missing == true)") { await load() }
        .shows([.pins])
    }

    private var actions: PageActions {
        let pictures = pictures ?? PhonePagePictures(model: model, folder: folder)
        return PageActions(
            save: { [model, folder, path] _, document in await model.writePage(path, in: folder, text: document) },
            image: { url in await pictures.image(url) },
            stamp: { url in await pictures.stamp(url) },
            canEdit: model.isConnected)
    }

    private func load() async {
        if pictures == nil { pictures = PhonePagePictures(model: model, folder: folder) }
        do {
            switch try await model.readPage(path, in: folder, known: stamp) {
            case .text(let read, _, _, let at):
                text = read
                stamp = at
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
            problem = "\(path) can't be read."
        }
    }
}

/// A page tile's page (#159): the top of the project's document or HTML page, live, and
/// Open for the whole of it.
struct PageTileBody: View {
    @Environment(RemoteModel.self) private var model
    let folder: URL
    let file: String

    @State private var text: String?
    @State private var stamp: FileStamp?
    @State private var problem: String?

    /// A third of a phone's screen.
    static let height: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                } else if let text {
                    if PinRules.kind(file) == .html {
                        HTMLPage(text: text, path: folder.appending(path: file).path(percentEncoded: false),
                                 scope: HTMLPageScope(root: folder.path(percentEncoded: false)),
                                 allowsScripts: false, folderEvent: model.work.pageRevision(in: folder),
                                 read: { [model, folder] path in try await model.readPage(path, in: folder) },
                                 follow: { _ in })
                    } else {
                        // Read-only, as a note is: a live page that can't be typed on draws
                        // its passages as disabled controls, greyed.
                        MarkdownText(markdown: text, base: folder.appending(path: file))
                            .appText(.supporting)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: problem == nil ? Self.height : nil,
                   maxHeight: problem == nil ? Self.height : nil, alignment: .top)
            .clipped()
            Button("Open") { model.openPin = file }
                .appText(.fine)
        }
        .task(id: model.work.pageRevision(in: folder)) {
            do {
                switch try await model.readPage(file, in: folder, known: stamp) {
                case .text(let read, _, _, let at):
                    text = read
                    stamp = at
                    problem = nil
                case .unchanged: break
                case .image, .other: problem = "\(file) can't be shown as a page."
                }
            } catch {
                problem = "\(file) isn't in the project folder."
            }
        }
    }
}

/// The pictures beside a pinned page, read through the Mac and kept with their stamps.
@MainActor
final class PhonePagePictures {
    private struct Held {
        var stamp: FileStamp
        var image: UIImage?
    }

    private let model: RemoteModel
    private let folder: URL
    private var held: [URL: Held] = [:]

    init(model: RemoteModel, folder: URL) {
        self.model = model
        self.folder = folder
    }

    func stamp(_ url: URL) async -> FileStamp? { await refresh(url)?.stamp }

    func image(_ url: URL) async -> UIImage? {
        if let image = held[url]?.image { return image }
        return await refresh(url)?.image
    }

    private func refresh(_ url: URL) async -> Held? {
        let known = held[url]
        guard let reading = try? await model.readPage(url.path(percentEncoded: false), in: folder,
                                                      known: known?.stamp) else { return known }
        switch reading {
        case .unchanged:
            return known
        case .image(let bytes, _, let stamp):
            let fresh = Held(stamp: stamp, image: UIImage(data: bytes))
            held[url] = fresh
            return fresh
        case .text(_, _, _, let stamp), .other(_, _, let stamp):
            let fresh = Held(stamp: stamp, image: nil)
            held[url] = fresh
            return fresh
        }
    }
}
