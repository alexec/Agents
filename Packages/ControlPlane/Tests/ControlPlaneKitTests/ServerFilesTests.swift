@testable import ControlPlaneKit
import Foundation
import Testing

/// The MCP servers Agents ships (#700) are handed out beside agentsd, by name and checksum.
@Suite("Server files: agentsd and the shipped MCP servers")
struct ServerFilesTests {
    @Test func theShippedServersAreServedAndNothingElse() {
        for arch in ["x86_64", "aarch64"] {
            #expect(ServerFiles.names.contains("ci-watcher-linux-\(arch)"))
            #expect(ServerFiles.names.contains("ci-watcher-linux-\(arch).sha256"))
        }
        #expect(ServerFiles.read("ci-watcher", in: URL(filePath: "/")) == nil)
    }

    @Test func aFolderGivesEachShippedServerItHas() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "server-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("0+1".utf8).write(to: folder.appending(path: "VERSION"))
        try Data("binary".utf8).write(to: folder.appending(path: "ci-watcher-linux-aarch64"))
        try Data("abc123\n".utf8).write(to: folder.appending(path: "ci-watcher-linux-aarch64.sha256"))

        let servers = ServerFiles.shippedServers(for: "aarch64", in: folder)
        #expect(servers.map(\.name) == ["ci-watcher"])
        #expect(servers.map(\.sha256) == ["abc123"])
        #expect(servers.map(\.file.lastPathComponent) == ["ci-watcher-linux-aarch64"])
        #expect(ServerFiles.shippedServers(for: "x86_64", in: folder).isEmpty, "none built for it")
        #expect(ServerFiles.shippedServers(for: "aarch64", in: nil).isEmpty)
    }

    /// The script a server runs fetches each shipped server, and a missing one is no failure.
    @Test func theInstallScriptFetchesTheShippedServers() {
        for name in ServerFiles.shippedServers {
            #expect(HostInstallScript.text.contains("for server in \(name)"))
        }
        #expect(HostInstallScript.text.contains("the host runs without it"))
    }
}
