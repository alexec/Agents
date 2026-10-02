import Foundation
import Testing
@testable import AgentsKit

/// A folder sent as a bare path once aborted the daemon: `Process` raises an Objective-C
/// exception for a working directory that is not a file URL (agentsd crash reports of
/// 2026-09-24, nine in four minutes).
@Suite("A runtime's folder")
struct RuntimeProcessFolderTests {
    @Test func aBarePathStartsTheProcessInThatFolder() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "rp-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let bare = try #require(URL(string: folder.path(percentEncoded: false)))
        #expect(!bare.isFileURL)

        let exited = AsyncStream<Int32>.makeStream()
        let process = try RuntimeProcess(executable: URL(filePath: "/bin/pwd"), arguments: [],
                                         cwd: bare, environment: [:],
                                         onExit: { exited.continuation.yield($0) })
        var status: Int32?
        for await code in exited.stream { status = code; break }
        #expect(status == 0)
        process.cleanUp()
    }

    @Test func aFileURLIsKeptAsItIs() {
        let url = URL(filePath: "/tmp", directoryHint: .isDirectory)
        #expect(RuntimeProcess.folderURL(url) == url)
    }
}
