import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Browsing a server's folders to choose one as a project (037).
@Suite("Browsing folders")
struct FilesBrowseTests {
    private func core() throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsBrowseTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("api"), withIntermediateDirectories: true)
        try "x".write(to: work.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let locations = StoreLocations(root: root)
        return (DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                           launcher: FakeLauncher()), work)
    }

    private func browse(_ core: DaemonCore, _ path: String?) async -> Result<JSONValue, JSONRPCError> {
        await core.handle(method: DaemonAPI.Method.filesBrowse,
                          params: try? JSONValue.encoding(DaemonAPI.FilesBrowseRequest(path: path)))
    }

    @Test func anAbsoluteFolderIsListedWithFoldersAndFiles() async throws {
        let (core, work) = try core()
        let listing = try await browse(core, work.path).get().decode(DirectoryListing.self)
        #expect(listing.entries.map(\.name).sorted() == ["api", "notes.txt"])
        #expect(listing.entries.first { $0.name == "api" }?.isDirectory == true)
    }

    @Test func nothingOrTildeIsHome() async throws {
        let (core, _) = try core()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for path in [nil, "~"] as [String?] {
            let listing = try await browse(core, path).get().decode(DirectoryListing.self)
            #expect(listing.url.standardizedFileURL.path == home)
        }
    }

    @Test func aRelativePathOrAFileIsRefused() async throws {
        let (core, work) = try core()
        guard case .failure = await browse(core, "src") else { Issue.record("relative accepted"); return }
        guard case .failure = await browse(core, work.appendingPathComponent("notes.txt").path) else {
            Issue.record("a file was listed"); return
        }
    }
}
