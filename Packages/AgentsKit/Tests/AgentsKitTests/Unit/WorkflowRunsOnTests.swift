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
        // No runtime: Auto (#2873), never the default a person's new session gets.
        let fallback = WorkflowSettings().runsOn()
        #expect(fallback.runtimeID == "auto")
        #expect(fallback.isAuto)
        #expect(fallback.line == "Runs on Auto (the default)")
        #expect(fallback.unknown == nil)
        #expect(WorkflowSettings(runtimeID: "auto").runsOn().line == "Runs on Auto (named in the file)")
        #expect(WorkflowSettings(runtimeID: "auto").runsOn().unknown == nil)
    }

    @Test func autoSaysWhatItPickedAndThatEffortDoesNothing() {
        let name = { (id: String) in RuntimeCatalog.runtime(id: id)?.name ?? id }
        #expect(WorkflowSettings.picked(nil, name: name) == nil)
        let pick = AutoPick(runtimeID: "codex", levels: Levels(),
                            skipped: [AutoSkip(runtimeID: "claude", reason: "not signed in")])
        #expect(WorkflowSettings.picked(pick, name: name) == "Auto picked Codex. Claude: not signed in")
        #expect(WorkflowSettings.picked(AutoPick(runtimeID: "codex", levels: Levels()), name: name) == "Auto picked Codex")
        #expect(WorkflowSettings(effort: "high").autoEffortNote == "On Auto, effort follows the model, so `effort: high` does nothing.")
        #expect(WorkflowSettings(runtimeID: "claude", effort: "high").autoEffortNote == nil)
        #expect(WorkflowSettings.autoPermissionOption.options?.compactMap(\.value.stringValue)
            == ["plan", "ask", "approve-for-me", "bypass-permissions"])
        #expect(WorkflowSettings.autoModelOption.options?.compactMap(\.value.stringValue) == ["fast", "balanced", "smart"])
        #expect(WorkflowSettings(runtimeID: "claude").summary == "on Claude")
        #expect(WorkflowSettings(runtimeID: "auto").summary == nil)
    }

    @Test func anUnknownRuntimeIsMarked() {
        let named = WorkflowSettings(runtimeID: "nope").runsOn()
        #expect(named.runtime == nil)
        #expect(named.line == "Runs on \"nope\" (named in the file)")
        #expect(named.unknown == "\"nope\" is not a runtime this version knows, so this workflow does not run.")
    }
}
