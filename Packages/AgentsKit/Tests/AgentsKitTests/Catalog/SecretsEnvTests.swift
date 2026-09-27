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
