import Foundation
import Testing
@testable import AgentsKitCore

/// The workflow page says which runtime a run will use and why (#2764), in the words the
/// web page says too, and marks a runtime this version does not know.
@Suite("A workflow says which runtime it runs on")
struct WorkflowRunsOnTests {
    @Test func theFileWinsThenTheLastUsedThenTheDefault() {
        let named = WorkflowSettings(runtimeID: "codex").runsOn(lastUsed: "grok")
        #expect(named.line == "Runs on Codex (named in the file)")
        #expect(named.unknown == nil)
        let last = WorkflowSettings().runsOn(lastUsed: "grok")
        #expect(last.runtimeID == "grok")
        #expect(last.line == "Runs on Grok (the last used here)")
        let fallback = WorkflowSettings().runsOn(lastUsed: nil)
        #expect(fallback.runtimeID == RuntimeCatalog.defaultRuntime.id)
        #expect(fallback.line == "Runs on \(RuntimeCatalog.defaultRuntime.name) (the default)")
    }

    @Test func anUnknownRuntimeIsMarked() {
        let named = WorkflowSettings(runtimeID: "nope").runsOn(lastUsed: "codex")
        #expect(named.runtime == nil)
        #expect(named.line == "Runs on \"nope\" (named in the file)")
        #expect(named.unknown == "\"nope\" is not a runtime this version knows, so this workflow does not run.")
        let last = WorkflowSettings().runsOn(lastUsed: "nope")
        #expect(last.unknown == "\"nope\" is not a runtime this version knows, so its settings cannot be shown.")
    }
}
