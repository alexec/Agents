import Foundation
import Testing
@testable import AgentsKitCore

/// Real failures are recognised for their runtime, and nothing else is (064, R11, SC-004).
@Suite("Sandbox failure detector")
struct SandboxFailureDetectorTests {
    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/sandbox-failures/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test(arguments: [
        ("claude", "claude-linux-missing-bwrap", "Sandbox required but unavailable"),
        ("claude", "claude-macos-nested-seatbelt", "sandbox_apply: Operation not permitted"),
        ("codex", "codex-macos-nested-seatbelt-reply", "sandbox_apply: Operation not permitted"),
        ("codex", "codex-linux-bwrap-no-namespace", "bwrap: No permissions to create a new namespace"),
        ("grok", "grok-macos-nested-seatbelt", "Refusing to start with its protections missing"),
        ("gemini", "gemini-linux-no-container", "failed to determine command for sandbox"),
    ])
    func aRealFailureIsRecognised(runtimeID: String, name: String, words: String) throws {
        let detail = SandboxFailureDetector.match(runtimeID: runtimeID, text: try fixture(name))
        #expect(detail?.contains(words) == true, "\(name)")
        #expect(detail?.contains("\u{1B}") == false, "no colour codes in the details")
    }

    @Test(arguments: ["not-claude-denied-inside-sandbox", "not-codex-denied-inside-sandbox"])
    func aCommandDeniedInsideAWorkingSandboxIsNot(name: String) throws {
        let text = try fixture(name)
        for runtime in RuntimeCatalog.builtIn {
            #expect(SandboxFailureDetector.match(runtimeID: runtime.id, text: text) == nil, "\(runtime.id) \(name)")
        }
    }

    @Test func otherFailuresAreNot() {
        let others = [
            "Authentication required",
            "API error (status 402 Payment Required): Grok Build usage balance exhausted",
            "You have exceeded your monthly quota",
            "The user refused permission to run this command.",
            "rm: /etc/hosts: Operation not permitted",
        ]
        for text in others {
            for runtime in RuntimeCatalog.builtIn {
                #expect(SandboxFailureDetector.match(runtimeID: runtime.id, text: text) == nil, "\(runtime.id): \(text)")
            }
        }
    }

    @Test func aReplyRunIntoTheErrorIsTrimmedToIt() throws {
        let detail = SandboxFailureDetector.match(runtimeID: "codex", text: try fixture("codex-macos-nested-seatbelt-reply"))
        #expect(detail == "sandbox-exec: sandbox_apply: Operation not permitted")
    }

    @Test func aRuntimeWithoutARouteRecognisesNothing() throws {
        #expect(SandboxFailureDetector.match(runtimeID: "cursor", text: try fixture("claude-macos-nested-seatbelt")) == nil)
        #expect(SandboxFailureDetector.match(runtimeID: "opencode", text: try fixture("grok-macos-nested-seatbelt")) == nil)
    }
}
