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

    /// The Go host (#1136) is served beside the Swift one, by its own names and version,
    /// and the Swift one stays the default.
    @Test func theGoHostIsServedBesideTheSwiftOne() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "server-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("1.0+5".utf8).write(to: folder.appending(path: "VERSION"))
        try Data("1.0+5".utf8).write(to: folder.appending(path: "VERSION-go"))
        try Data("swift\n".utf8).write(to: folder.appending(path: "agentsd-linux-aarch64.sha256"))
        try Data("go\n".utf8).write(to: folder.appending(path: "agentsd-go-linux-aarch64.sha256"))

        #expect(ServerFiles.names.contains("agentsd-go-linux-x86_64"))
        #expect(ServerFiles.names.contains("VERSION-go"))
        #expect(ServerFiles.binary(for: "aarch64", in: folder)?.sha256 == "swift")
        let go = try #require(ServerFiles.binary(for: "aarch64", implementation: "go", in: folder))
        #expect(go.sha256 == "go")
        #expect(go.file.lastPathComponent == "agentsd-go-linux-aarch64")
        #expect(ServerFiles.binary(for: "x86_64", implementation: "go", in: folder) == nil, "none built for it")
    }

    @Test func theCommandAsksForTheGoHostOnlyWhenTold() {
        let swift = HostInstallScript.command(url: "https://plane:8787/", pin: nil, code: "agents-control:2:h:x")
        #expect(swift == "curl -fsSL https://plane:8787/v1/install.sh | sh -s -- 'agents-control:2:h:x'")
        let go = HostInstallScript.command(url: "https://plane:8787", pin: nil, code: "agents-control:2:h:x", implementation: "go")
        #expect(go.hasSuffix("sh -s -- 'agents-control:2:h:x' --impl go"))
        #expect(HostInstallScript.text.contains(#"go) program=agentsd-go"#))
        #expect(HostInstallScript.text.contains("/v1/servers/$program-linux-$arch"))
    }
}
