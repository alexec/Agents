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
