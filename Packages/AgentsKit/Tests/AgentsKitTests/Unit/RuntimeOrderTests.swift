import Foundation
import Testing
@testable import AgentsKitCore

/// Runtimes are listed alphabetically by the name shown, wherever they are listed (#154):
/// sorted once in the catalog, so the daemon's replies and every client inherit it.
@Suite("The order runtimes are listed in")
struct RuntimeOrderTests {
    @Test func theCatalogIsAlphabeticalByName() {
        #expect(RuntimeCatalog.builtIn.map(\.name)
                == ["Antigravity", "Claude", "Codex", "Copilot", "Cursor", "Gemini", "Grok", "OpenCode"])
    }

    @Test func theDefaultIsClaudeWhereverItSorts() {
        #expect(RuntimeCatalog.defaultRuntime == RuntimeCatalog.claude)
    }

    @Test func caseDoesNotCountAndTheIdBreaksATie() {
        let sent = [Runtime(id: "b", name: "beta", executable: "b", arguments: []),
                    Runtime(id: "z", name: "Alpha", executable: "z", arguments: []),
                    Runtime(id: "a", name: "alpha", executable: "a", arguments: [])]
        #expect(RuntimeCatalog.sortedByName(sent).map(\.id) == ["a", "z", "b"])
    }

    /// A server on an older build answers in its own catalog's order; the client sorts it.
    @Test func aDaemonsListIsSortedOnArrival() {
        let sent = [RuntimeCatalog.grok, RuntimeCatalog.claude, RuntimeCatalog.antigravity]
            .map { RuntimeStatus(runtime: $0, availability: .missing(lookedIn: [])) }
        #expect(RuntimeCatalog.sortedByName(sent).map(\.id) == ["antigravity", "claude", "grok"])
        #expect(RuntimeCatalog.sortedByName(ids: ["opencode", "codex", "unknown", "antigravity"])
                == ["antigravity", "codex", "opencode", "unknown"])
    }
}
