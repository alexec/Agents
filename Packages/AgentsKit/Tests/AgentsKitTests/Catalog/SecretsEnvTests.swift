#if canImport(CryptoKit)
import Foundation
import Testing
@testable import AgentsKit

@Suite("secrets.env")
struct SecretsEnvTests {
    private var dir: URL {
        FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString)")
    }

    @Test func roundTripAndEqualsInValue() throws {
        let home = dir
        try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        let url = SecretsEnv.url(home: home)
        var env = SecretsEnv(lines: [
            .init(kind: .other("# keep me")),
            .init(kind: .assignment(name: "A", value: "one")),
        ])
        env.set("B", value: "x=y=z")
        try env.save(to: url)

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let loaded = SecretsEnv.load(from: url)
        #expect(loaded.names == ["A", "B"])
        #expect(loaded.value(of: "B") == "x=y=z")
        #expect(loaded.text().contains("# keep me"))
    }

    /// Secrets are not configuration (#1035): they go in `~/.agents-secrets`, a folder only
    /// its owner can open, never in `~/.agents`, which a person may copy or commit.
    @Test func secretsLiveOutsideDotAgentsInAPrivateFolder() throws {
        let home = dir
        let secrets = SecretsEnv.url(home: home)
        let signIns = MCPSignInFile.url(home: home)
        #expect(secrets.path == home.appending(path: ".agents-secrets/secrets.env").path)
        #expect(signIns.path == home.appending(path: ".agents-secrets/mcp-sign-ins.json").path)

        try SecretsEnv.parse("A=one\n").save(to: secrets)
        try MCPSignInFile().save(to: signIns)
        let folder = secrets.deletingLastPathComponent()
        func mode(_ url: URL) throws -> Int? {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        }
        #expect(try mode(folder) == 0o700)
        #expect(try mode(secrets) == 0o600)
        #expect(try mode(signIns) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".agents").path))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try SecretsEnv.parse("A=two\n").save(to: secrets)
        #expect(try mode(folder) == 0o700, "a save puts the folder back to owner only")
    }

    @Test func setReplacesPreservesForeignLines() {
        var env = SecretsEnv.parse("FOO=1\n# comment\nBAR=2\n")
        env.set("FOO", value: "nine")
        #expect(env.value(of: "FOO") == "nine")
        #expect(env.names == ["FOO", "BAR"])
        #expect(env.text().contains("# comment"))
    }

    @Test func fillSubstitutesAndFailsWhenMissing() {
        var env = SecretsEnv(lines: [])
        env.set("TOKEN", value: "secret")
        #expect(env.fill("Bearer ${TOKEN}") == "Bearer secret")
        #expect(env.fill("Bearer ${MISSING}") == nil)

        let server = MCPServer(name: "g", transport: .http(url: "https://x", headers: ["Authorization": "Bearer ${TOKEN}"]))
        #expect(env.filled(server)?.transport == .http(url: "https://x", headers: ["Authorization": "Bearer secret"]))
        let missing = MCPServer(name: "g", transport: .http(url: "https://x", headers: ["Authorization": "Bearer ${NO}"]))
        #expect(env.filled(missing) == nil)
    }
}
#endif
