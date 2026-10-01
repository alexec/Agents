import Foundation
import Testing
@testable import AgentsKitCore

/// A folder in the files pane always ends on its contents or a sentence, never on
/// "Reading…" for good (#62).
@Suite("Files pane reads")
struct FilesPaneReadsTests {
    // MARK: The tree

    private let root = URL(filePath: "/work", directoryHint: .isDirectory)
    private func folder(_ path: String) -> URL { URL(filePath: "/work/\(path)", directoryHint: .isDirectory) }
    private func listing(_ url: URL, folders: [String]) -> DirectoryListing {
        DirectoryListing(url: url, entries: folders.map {
            DirectoryEntry(url: url.appending(path: $0, directoryHint: .isDirectory), name: $0, isDirectory: true)
        })
    }

    /// The cause: the pane read only the open folders whose parents were already
    /// listed, so a pane drawn afresh with folders still open (or a deep file revealed)
    /// read the top alone, and every open folder under it said "Reading…" for good.
    @Test func anOpenFolderIsReadOnceItsParentIsListed() {
        let expanded: Set<String> = ["/work/a", "/work/a/b"]
        var listings: [String: DirectoryListing] = [:]
        #expect(FileTree.unread(root: root, expanded: expanded, listings: listings).map(FileTree.key) == ["/work"])

        listings["/work"] = listing(root, folders: ["a", "z"])
        #expect(FileTree.unread(root: root, expanded: expanded, listings: listings).map(FileTree.key) == ["/work/a"])
        // One already on its way is not asked for twice.
        #expect(FileTree.unread(root: root, expanded: expanded, listings: listings, reading: ["/work/a"]).isEmpty)

        listings["/work/a"] = listing(folder("a"), folders: ["b"])
        #expect(FileTree.unread(root: root, expanded: expanded, listings: listings).map(FileTree.key) == ["/work/a/b"])
        // A folder that said why it could not be read has something on screen.
        #expect(FileTree.unread(root: root, expanded: expanded, listings: listings, problems: ["/work/a/b"]).isEmpty)

        listings["/work/a/b"] = listing(folder("a/b"), folders: [])
        #expect(FileTree.unread(root: root, expanded: expanded, listings: listings).isEmpty)
        #expect(FileTree.visibleFolders(root: root, expanded: expanded, listings: listings).map(FileTree.key)
                == ["/work", "/work/a", "/work/a/b"])
    }

    @Test func keysIgnoreATrailingSlash() {
        #expect(FileTree.key(URL(filePath: "/work/a/")) == FileTree.key(URL(filePath: "/work/a")))
    }

    // MARK: A read that never answers

    /// A host that answers pings and nothing else: a reply lost on the way back.
    final class Host: DaemonLink, @unchecked Sendable {
        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            _ = Task {
                for try await line in far.lines() {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = object["id"] as? Int, object["method"] as? String == DaemonAPI.Method.ping else { continue }
                    try? far.write(line: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
                }
            }
            return near
        }
    }

    @Test @MainActor func aListingThatNeverAnswersSaysSo() async throws {
        let client = DaemonClient(link: Host())
        try await client.connect(startIfNeeded: false)
        let files = RemoteFiles(client: client, patience: .milliseconds(200))
        let started = ContinuousClock.now
        do {
            _ = try await files.list(agentID: UUID(), folder: folder("a"))
            Issue.record("a listing nobody answered came back")
        } catch {
            #expect(RemoteFiles.isNoAnswer(error))
            #expect(RemoteFiles.describe(error, name: "a") == "a took too long to read.")
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test @MainActor func aFileThatNeverAnswersSaysSo() async throws {
        let client = DaemonClient(link: Host())
        try await client.connect(startIfNeeded: false)
        let files = RemoteFiles(client: client, patience: .milliseconds(200))
        await #expect(throws: RemoteFiles.NoAnswer.self) {
            _ = try await files.read(agentID: UUID(), path: "/work/notes.md")
        }
    }

    // MARK: A connection that ended

    /// A host client whose connection ended is not connected, so the window dials it
    /// again rather than sending every read down a closed line.
    @Test func aClosedConnectionIsNotConnected() async throws {
        final class Ends: DaemonLink, @unchecked Sendable {
            let far = FarEndBox<PairedTransport>()
            func transport() async throws -> any LineTransport {
                let (near, far) = PairedTransport.pair()
                self.far.value = far
                _ = Task {
                    for try await line in far.lines() {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              let id = object["id"] as? Int else { continue }
                        try? far.write(line: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
                    }
                }
                return near
            }
        }
        let link = Ends()
        let client = DaemonClient(link: link)
        try await client.connect(startIfNeeded: false)
        #expect(await client.isConnected)
        link.far.value?.close()
        let deadline = ContinuousClock.now + .seconds(5)
        while await client.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await !client.isConnected)
    }
}

private final class FarEndBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: T?
    var value: T? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// Back from a file finds the tree where it was, with the file marked (#66).
@Suite("Files pane place")
struct FilesPanePlaceTests {
    private let file = URL(filePath: "/work/a/b/notes.txt")
    private let rows = ["/work/a", "/work/a/b", "/work/a/b/notes.txt", "/work/z.txt"]

    /// Chosen from a row: it is in view already, and the kept tree is not moved.
    @Test func aFileChosenFromTheTreeIsMarkedAndLeftWhereItIs() {
        var place = FileTreePlace()
        place.opened(file, fromRow: true)
        #expect(place.marked == "/work/a/b/notes.txt")
        #expect(place.scroll(among: rows) == nil)
    }

    /// Opened from the chat, a card or `show_file`: scrolled to once its folder has
    /// been read, and once only, so the person's own scrolling after is theirs.
    @Test func aFileOpenedFromElsewhereIsScrolledToOnceItsRowIsRead() {
        var place = FileTreePlace()
        place.opened(file, fromRow: false)
        #expect(place.scroll(among: ["/work/a"]) == nil)
        #expect(place.scroll(among: rows) == "/work/a/b/notes.txt")
        #expect(place.scroll(among: rows) == nil)
        #expect(place.marked == "/work/a/b/notes.txt")
    }

    /// A tree drawn new (the pane closed and opened, the window opened) finds the
    /// file last open again; a reload of the same tree does not.
    @Test func aTreeDrawnAfreshFindsTheMarkedFileAgain() {
        var place = FileTreePlace()
        place.drawnAfresh()
        #expect(place.scroll(among: rows) == nil)
        place.opened(file, fromRow: true)
        place.drawnAfresh()
        #expect(place.scroll(among: rows) == "/work/a/b/notes.txt")
    }

    /// The same file opened again from elsewhere, after the person scrolled away from
    /// it, is brought back into view.
    @Test func theSameFileFromElsewhereIsScrolledToAgain() {
        var place = FileTreePlace()
        place.opened(file, fromRow: true)
        place.opened(URL(filePath: "/work/a/b/notes.txt/"), fromRow: false)
        #expect(place.scroll(among: rows) == "/work/a/b/notes.txt")
    }

    @Test func movingFolderForgetsTheMark() {
        var place = FileTreePlace()
        place.opened(file, fromRow: false)
        place.forget()
        #expect(place.marked == nil)
        #expect(place.scroll(among: rows) == nil)
    }
}
