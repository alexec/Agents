import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a workflow says about how it runs, and what happens when the runtime will not
/// have it.
///
/// The test this suite is really for is `aModeTheRuntimeDoesNotOfferIsRefusedAndNotSubstituted`,
/// which arrives with US1. Every substitution that could be made in its place is in the
/// permissive direction — the mode that was asked for is the restrictive one, and the
/// thing to fall back to is always more allowed, not less — and nobody is watching when
/// a workflow fires at nine in the morning. Refusing is the feature.
@Suite("What a workflow says about how it runs")
struct WorkflowSettingsTests {
    private let project = URL(filePath: "/tmp/a-project")

    private func parse(_ text: String, id: String = "morning-build-check") -> Workflow {
        WorkflowFile.parse(text, workflowID: id, in: project)
    }

    private func file(_ frontMatter: String) -> String {
        """
        ---
        on:
          - schedule:
              at: [":00"]
        agent: new
        \(frontMatter)
        ---

        Check whether the build is still green.
        """
    }

    // MARK: Reading a file

    @Test func aFileWithNoSettingsStartsAsItAlwaysDid() {
        let workflow = parse(file("name: Morning build check"))
        #expect(workflow.problem == nil)
        #expect(workflow.settings.isEmpty)
        #expect(workflow.settings.summary == nil)
    }

    @Test func settingsSurviveAFileThatAlsoCarriesKeysWeDoNotKnow() {
        let workflow = parse(file("""
            permission-mode: plan
            runtime: grok
            model: grok-4
            colour: blue
            """))
        #expect(workflow.problem == nil)
        #expect(workflow.settings.permissionMode == "plan")
        #expect(workflow.settings.runtimeID == "grok")
        #expect(workflow.settings.model == "grok-4")
        // The three are read and the fourth is kept: a later version's key must survive
        // this version having no idea what it is.
        #expect(workflow.unknownFields["colour"] == .string("blue"))
        #expect(workflow.unknownFields["permission-mode"] == nil)
    }

    // MARK: What the row says

    @Test func theSummaryLeavesOutTheDefaultRuntime() {
        let onDefault = WorkflowSettings(permissionMode: "plan", runtimeID: "claude")
        #expect(onDefault.summary == "in plan mode")

        let elsewhere = WorkflowSettings(permissionMode: "plan", runtimeID: "grok", model: "grok-4")
        #expect(elsewhere.summary == "in plan mode, on Grok, using grok-4")
    }

    @Test func aTriggeringWorkflowDoesNotClaimAModeItWillNeverApply() {
        let workflow = parse("""
            ---
            on:
              - agent-finished
            agent: triggering
            permission-mode: plan
            ---

            Say how it went.
            """)
        #expect(workflow.mode == .triggering)
        #expect(workflow.settings.permissionMode == "plan")
        // The setting is in the file and the page will say so. The row must not, because
        // a triggering workflow resumes an agent that is already started and never
        // applies it.
        #expect(!workflow.summary.contains("plan"))
    }
}
