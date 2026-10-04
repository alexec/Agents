import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `secrets.env` and `mcp.json` that cannot be read are refused, never written over (#205).
///
/// For each: a file this process may not read, and a corrupt one. The write is refused,
/// and the file is still there, byte for byte, with its mode.
@Suite("Unreadable secrets and mcp.json are kept", .timeLimit(.minutes(1)))
struct UnreadableSecretsTests {
    private let fileManager = FileManager.default

    private func home() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnreadableSecrets-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        return home
    }

    private func installer(_ home: URL) -> MCPInstaller {
        MCPInstaller(sidecar: home.appending(path: "catalog-mcp.json"), approvals: home.appending(path: "mcp-approvals.json"))
    }

    private func mode(_ url: URL) throws -> Int? {
        (try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    /// Run `body` with `url` at mode 000, then put it back to `mode`.
    private func unreadable(_ url: URL, mode: Int = 0o600, _ body: () throws -> Void) throws {
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        try body()
    }

    private let secrets = Data("A=one\nB=two\n".utf8)

    // MARK: secrets.env

    @Test func aSecretsFileThatMayNotBeReadIsNotWrittenOver() throws {
        let home = try home()
        let url = SecretsEnv.url(home: home)
        try secrets.write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try unreadable(url) {
            #expect(throws: DaemonAPI.MCPCatalogError.self) {
                try installer(home).setSecret(name: "C", value: "three", personalHome: home)
            }
            #expect(throws: SecretsEnv.Unreadable.self) { try SecretsEnv.loadForChange(from: url) }
        }
        #expect(try Data(contentsOf: url) == secrets, "every secret kept")
        #expect(try mode(url) == 0o600)
    }

    @Test func aSecretsFileThatIsNotTextIsNotWrittenOver() throws {
        let home = try home()
        let url = SecretsEnv.url(home: home)
        let bytes = secrets + Data([0xFF, 0xFE, 0x0A])
        try bytes.write(to: url)

        #expect(throws: DaemonAPI.MCPCatalogError.self) {
            try installer(home).setSecret(name: "C", value: "three", personalHome: home)
        }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(SecretsEnv.load(from: url).names.isEmpty, "reading it for display is still allowed, as nothing")
    }

    /// Conflict markers are lines it keeps as they are; the secrets around them stay.
    @Test func conflictMarkersInSecretsAreCarriedThrough() throws {
        let home = try home()
        let url = SecretsEnv.url(home: home)
        try Data("A=one\n<<<<<<< HEAD\nB=two\n=======\nB=three\n>>>>>>> other\n".utf8).write(to: url)

        try installer(home).setSecret(name: "C", value: "four", personalHome: home)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("A=one") && text.contains("<<<<<<< HEAD") && text.contains("B=three") && text.contains("C=four"))
    }

    /// A save is a rename over the old file: it is never removed first, and the new one is
    /// 0600 from the moment it is made, so nothing beside it is ever readable by others.
    @Test func aSaveRenamesOverAndIsPrivateFromTheStart() throws {
        let home = try home()
        let url = SecretsEnv.url(home: home)
        try secrets.write(to: url)
        let before = try fileManager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int

        try installer(home).setSecret(name: "C", value: "three", personalHome: home)
        #expect(try mode(url) == 0o600)
        #expect(SecretsEnv.load(from: url).names == ["A", "B", "C"])
        #expect(try String(contentsOf: url, encoding: .utf8) == "A=one\nB=two\nC=three\n", "no blank line before the new one")
        #expect(try fileManager.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int != before, "a new file renamed in")
        let left = try fileManager.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(left == ["secrets.env"], "no .part or temporary left: \(left)")
    }

    @Test func removingAServerWithAnUnreadableSecretsFileChangesNothing() throws {
        let home = try home()
        let installer = installer(home)
        let mcp = MCPJSONFile.personalURL(home: home)
        try installer.setSecret(name: "DATABASE_URL", value: "x", personalHome: home)
        try MCPJSONFile.upsert(name: "pg", entry: .mcpEntry(stdio: "npx", args: ["${DATABASE_URL}"], env: []), at: mcp)
        var side = MCPCatalogSidecar.load(from: home.appending(path: "catalog-mcp.json"))
        side.upsert(destination: .personal, name: "pg",
                    record: .init(registryName: "r/pg", version: "1", run: "npx", addedAt: Date()))
        try side.save(to: home.appending(path: "catalog-mcp.json"))
        let servers = try Data(contentsOf: mcp)

        let url = SecretsEnv.url(home: home)
        try unreadable(url) {
            #expect(throws: DaemonAPI.MCPCatalogError.self) {
                try installer.remove("pg", destination: .personal, personalHome: home, forgetSecret: "DATABASE_URL")
            }
        }
        #expect(try Data(contentsOf: mcp) == servers, "the server is still there")
        #expect(SecretsEnv.load(from: url).value(of: "DATABASE_URL") == "x")
    }

    // MARK: mcp.json

    private let handWritten = Data(#"{"mcpServers":{"mine":{"command":"my-server"}}}"#.utf8)

    @Test func anMCPFileThatMayNotBeReadIsNotWrittenOver() throws {
        let home = try home()
        let url = MCPJSONFile.personalURL(home: home)
        try handWritten.write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)

        try unreadable(url, mode: 0o640) {
            #expect(throws: MCPJSONFile.Problem.self) {
                try MCPJSONFile.upsert(name: "new", entry: .mcpEntry(stdio: "x", args: [], env: []), at: url)
            }
        }
        #expect(try Data(contentsOf: url) == handWritten)
    }

    @Test func aCorruptMCPFileIsNotWrittenOver() throws {
        let home = try home()
        let url = MCPJSONFile.personalURL(home: home)
        let conflicted = Data("<<<<<<< HEAD\n{\"mcpServers\":{}}\n=======\n{}\n>>>>>>> b\n".utf8)
        try conflicted.write(to: url)
        #expect(throws: MCPJSONFile.Problem.self) {
            try MCPJSONFile.upsert(name: "new", entry: .mcpEntry(stdio: "x", args: [], env: []), at: url)
        }
        #expect(try Data(contentsOf: url) == conflicted)
    }

    /// Keys a newer build (or the person) wrote are carried through, and the file keeps
    /// its own mode.
    @Test func anMCPWriteKeepsEveryOtherKeyAndTheMode() throws {
        let home = try home()
        let url = MCPJSONFile.personalURL(home: home)
        try Data(#"{"futureKey":{"a":1},"mcpServers":{"mine":{"command":"my-server","newField":true}}}"#.utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try MCPJSONFile.upsert(name: "new", entry: .mcpEntry(stdio: "x", args: [], env: []), at: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("futureKey") && text.contains("newField") && text.contains("\"new\""))
        #expect(try mode(url) == 0o600)
    }
}
