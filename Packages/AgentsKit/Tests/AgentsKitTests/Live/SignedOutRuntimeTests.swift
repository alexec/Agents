import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a runtime actually does when it is not signed in.
///
/// 001 could not answer this and neither could the first half of 003: nothing on this
/// Mac is signed out. Rather than sign anybody out, each runtime is launched with a
/// `HOME` of its own and no token in the environment, so it cannot find credentials
/// while the real ones are left alone.
///
/// Opt-in: `AGENTS_LIVE=1 swift test --filter SignedOut`. No model is prompted, so this
/// costs nothing but the time to start a runtime.
@Suite("Live: a runtime that cannot find its credentials",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"),
       .timeLimit(.minutes(5)))
struct SignedOutRuntimeTests {
    /// Launches runtimes the way the app does, except that they cannot reach the user's
    /// credentials.
    struct SignedOutLauncher: SessionLauncher {
        let home: URL

        func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
            var environment = LoginShellPath.environment()
            environment["HOME"] = home.path
            for key in ["COPILOT_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN",
                        "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
                        "GROK_API_KEY", "XAI_API_KEY",
                        "CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"] {
                environment.removeValue(forKey: key)
            }
            return try ACPSession.launch(executable: URL(filePath: path),
                                         arguments: runtime.arguments,
                                         cwd: cwd,
                                         environment: environment,
                                         capabilities: .app)
        }
    }

    private func sandbox() throws -> (StoreLocations, URL, URL) {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "SignedOut-\(UUID().uuidString)")
        let work = root.appending(path: "work")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work, home)
    }

    @Test func copilotWithNoCredentialsIsReportedAsNeedingSignIn() async throws {
        let (locations, work, home) = try sandbox()
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              launcher: SignedOutLauncher(home: home))

        do {
            _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "hello"))
            Issue.record("Copilot started a session without credentials")
        } catch let error as JSONRPCError {
            // Recorded on 2026-09-18: `initialize` succeeds, `session/new` answers
            // -32000 "Authentication required".
            #expect(error.code == DaemonAPI.Failure.needsSignIn)
            #expect(error.message.contains("needs signing in"))
            let methods = try? error.data?["authMethods"]?.decode([ACP.AuthMethod].self)
            #expect(methods?.first?.id == "copilot-login")
            #expect(methods?.first?.terminalCommand?.contains("login") == true,
                    "the command Copilot names is what the app shows")
        }

        // And the runtime is marked, so the app can offer to fix it rather than asking
        // again and failing again.
        #expect(await core.account(for: "copilot").state == .needsSignIn)
    }

    @Test func grokWithNoCredentialsSaysTheSameThingItsOwnWay() async throws {
        let (locations, work, home) = try sandbox()
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              launcher: SignedOutLauncher(home: home))

        do {
            _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "hello"))
            Issue.record("Grok started a session without credentials")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.needsSignIn)
        }
        #expect(await core.account(for: "grok").state == .needsSignIn)
    }

    /// The fourth runtime, added by 006. Its User Story 2 says the app must tell
    /// "not installed" from "installed and signed out", and until this harness existed
    /// there was no way to see the second one without signing somebody out for real.
    @Test func cursorWithNoCredentialsSaysSoToo() async throws {
        let (locations, work, home) = try sandbox()
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              launcher: SignedOutLauncher(home: home))

        do {
            _ = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "hello"))
            Issue.record("Cursor started a session without credentials")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.needsSignIn)
            let methods = try? error.data?["authMethods"]?.decode([ACP.AuthMethod].self)
            #expect(methods?.first?.id == "cursor_login")
            // What it says to do is not what the app would do. `agent` here is Grok, so
            // the sentence naming it is dropped before any of this reaches a person.
            #expect(methods?.first?.terminalCommand == nil, "Cursor names no command properly")
            #expect(methods?.first?.guidance?.contains("agent login") != true)
        }
        #expect(await core.account(for: "cursor").state == .needsSignIn)
    }
}
