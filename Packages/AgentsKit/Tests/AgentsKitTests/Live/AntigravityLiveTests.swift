import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Google's real Antigravity ACP server (049), started the way the daemon starts it.
///
/// `AGENTS_ANTIGRAVITY_SERVER` is the path of an unpacked `agy_acp_server.par` (the
/// set-up page's copy, or one unzipped by hand). Needs the internet, and nothing of the
/// person's: its home is a folder of the test's own, and `~/.gemini` is compared before
/// and after. The app offers Antigravity a Google sign-in only (049 D3), so a real turn
/// needs a browser and is not here; a fake key is how a failing turn is reached.
@Suite("Antigravity, for real",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_ANTIGRAVITY_SERVER"] != nil),
       .timeLimit(.minutes(3)))
struct AntigravityLiveTests {
    let server = ProcessInfo.processInfo.environment["AGENTS_ANTIGRAVITY_SERVER"] ?? ""

    private func start(key: String?) throws -> (ACPSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-live-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let launch = RuntimeLaunchCatalog.antigravity
        for folder in launch.folders(root: root.path) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        var environment = ProcessSessionLauncher.environment(for: ToolPolicyCatalog.antigravity,
                                                             locations: locations,
                                                             onto: LoginShellPath.environment())
        if let key { environment["GEMINI_API_KEY"] = key }
        let session = try ACPSession.launch(executable: URL(fileURLWithPath: server), arguments: [],
                                            cwd: work, environment: environment, capabilities: .app,
                                            launch: launch)
        return (session, work)
    }

    /// `~/.gemini`, but for the one thing Google's harness puts there whatever
    /// `GEMINI_HOME` says: its video encoder, in `antigravity/bin/` (049, research R5). It
    /// finds that folder through `$HOME`, which the agent's own shell needs left alone.
    private static func gemini() -> [String: Data] {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")
        let files = (FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { !$0.path.contains("/.gemini/antigravity/bin") }
        return Dictionary(uniqueKeysWithValues: files.compactMap { url in
            (try? Data(contentsOf: url)).map { (url.path, $0) }
        })
    }

    @Test func withNoKeyItAsksToBeSignedInAndOffersGoogleFirst() async throws {
        let before = Self.gemini()
        let (session, work) = try start(key: nil)
        let hello = try await session.initialize()
        #expect(hello.authMethods?.map(\.id).contains("oauth-personal") == true)
        do {
            try await session.newSession(cwd: work, meta: ToolPolicyCatalog.antigravity.sessionMeta)
            Issue.record("a session without signing in")
        } catch let error as JSONRPCError {
            #expect(error.code == -32000, "the protocol's own sign-in refusal, which the app already reads")
        }
        await session.end(gracePeriod: .seconds(2))
        #expect(Self.gemini() == before, "the person's ~/.gemini is untouched")
    }

    /// A turn the real server fails, reached with a key Google refuses (signed in with by the
    /// test, not the app): it ends in words, and the session reads them as a failure.
    @Test func aTurnTheServerFailsIsReadFromItsWords() async throws {
        let before = Self.gemini()
        let (session, work) = try start(key: "not-a-real-key")
        _ = try await session.initialize()
        try await session.authenticate(methodID: "gemini-api-key")
        try await session.newSession(cwd: work, meta: ToolPolicyCatalog.antigravity.sessionMeta)
        let result = try await session.prompt("Say hi.")
        await session.end(gracePeriod: .seconds(2))
        let error = try #require(result.runtimeError)
        #expect(error.sentence.contains("API key not valid"))
        #expect(Self.gemini() == before, "the person's ~/.gemini is untouched")
    }
}
