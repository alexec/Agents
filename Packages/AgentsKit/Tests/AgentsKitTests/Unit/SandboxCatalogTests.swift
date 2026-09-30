import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Only measured routes are offered, and each says what it adds to a launch (064, R9).
@Suite("Sandbox catalog")
struct SandboxCatalogTests {
    @Test func everyRuntimeHasAnEntry() {
        for runtime in RuntimeCatalog.builtIn {
            #expect(SandboxCatalog.entry(for: runtime.id) != nil, "\(runtime.id)")
        }
    }

    @Test func choicesAreTheMeasuredOnes() {
        for id in ["claude", "codex", "grok"] {
            #expect(SandboxCatalog.choices(for: id) == [.runtime, .on, .off], "\(id)")
        }
        #expect(SandboxCatalog.choices(for: "gemini") == [.runtime, .off])
        for id in ["cursor", "copilot", "antigravity", "opencode"] {
            #expect(SandboxCatalog.choices(for: id).isEmpty, "\(id)")
            #expect(SandboxCatalog.entry(for: id)?.why != nil, "\(id)")
        }
    }

    @Test func statesAreWhatTheAppCanVouchFor() {
        #expect(SandboxCatalog.state(runtimeID: "grok", choice: .off) == .off)
        #expect(SandboxCatalog.state(runtimeID: "claude", choice: .runtime) == .runtimeControlled)
        #expect(SandboxCatalog.state(runtimeID: "codex", choice: .runtime, codexMode: "agent-full-access") == .off)
        #expect(SandboxCatalog.state(runtimeID: "codex", choice: .off, codexMode: "read-only") == .on)
        #expect(SandboxCatalog.state(runtimeID: "opencode", choice: .off) == .none)
        #expect(SandboxCatalog.state(runtimeID: "cursor", choice: .on) == .runtimeControlled)
    }

    @Test func whatEachChoiceAddsToALaunch() {
        #expect(LaunchSandbox.additions(runtimeID: "grok", choice: .off).arguments == ["--sandbox", "off"])
        #expect(LaunchSandbox.additions(runtimeID: "grok", choice: .on).arguments == ["--sandbox", "workspace"])
        #expect(LaunchSandbox.additions(runtimeID: "gemini", choice: .off).environment == ["GEMINI_SANDBOX": "false"])
        #expect(LaunchSandbox.additions(runtimeID: "gemini", choice: .on).environment.isEmpty)
        for id in RuntimeCatalog.builtIn.map(\.id) {
            let none = LaunchSandbox.additions(runtimeID: id, choice: .runtime)
            #expect(none.arguments.isEmpty && none.environment.isEmpty, "\(id) adds nothing as configured")
            #expect(LaunchSandbox.meta(runtimeID: id, choice: .runtime) == nil)
        }
        #expect(LaunchSandbox.meta(runtimeID: "claude", choice: .off)?["claudeCode"]?["options"]?["sandbox"]?["enabled"] == .bool(false))
        #expect(LaunchSandbox.meta(runtimeID: "grok", choice: .off) == nil)
    }
}
