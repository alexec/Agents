import Foundation
import Testing
@testable import AgentsKitCore

/// The workflow page says which runtime a run will use and why (#2764), in the words the
/// web page says too, and marks a runtime this version does not know.
@Suite("A workflow says which runtime it runs on")
struct WorkflowRunsOnTests {
    @Test func theFileWinsThenTheDefault() {
        let named = WorkflowSettings(runtimeID: "codex").runsOn()
        #expect(named.line == "Runs on Codex (named in the file)")
        #expect(named.unknown == nil)
        let fallback = WorkflowSettings().runsOn()
        #expect(fallback.runtimeID == RuntimeCatalog.defaultRuntime.id)
        #expect(fallback.line == "Runs on \(RuntimeCatalog.defaultRuntime.name) (the default)")
    }

    @Test func anUnknownRuntimeIsMarked() {
        let named = WorkflowSettings(runtimeID: "nope").runsOn()
        #expect(named.runtime == nil)
        #expect(named.line == "Runs on \"nope\" (named in the file)")
        #expect(named.unknown == "\"nope\" is not a runtime this version knows, so this workflow does not run.")
    }
}
