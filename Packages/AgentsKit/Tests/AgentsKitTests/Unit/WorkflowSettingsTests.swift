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

    // MARK: What the runtime is told

    /// A mode option whose id is deliberately not `mode`. A runtime gets to call it
    /// whatever it likes, and anything here that hard-codes the word fails on this.
    private let modeOption = ConfigOption(
        id: "permission_mode", name: "Mode", category: "mode", type: "select",
        currentValue: .string("default"),
        options: [ConfigChoice(value: .string("default"), name: "Manual"),
                  ConfigChoice(value: .string("acceptEdits"), name: "Accept edits"),
                  ConfigChoice(value: .string("bypassPermissions"), name: "Bypass permissions")])

    /// A model option found only by its category — its id is not `model`, so the second
    /// rule cannot be what finds it.
    private let modelOption = ConfigOption(
        id: "llm", name: "Model", category: "model", type: "select",
        options: [ConfigChoice(value: .string("opus"), name: "Opus"),
                  ConfigChoice(value: .string("sonnet"), name: "Sonnet")])

    private func resolved(_ settings: WorkflowSettings,
                          _ advertised: [ConfigOption]) -> StartOptions? {
        guard case .resolved(let options) = WorkflowSettings.resolve(settings, against: advertised) else {
            return nil
        }
        return options
    }

    private func refusal(_ settings: WorkflowSettings,
                         _ advertised: [ConfigOption]) -> (setting: String, value: String, offered: [String])? {
        guard case .refused(let setting, let value, let offered) =
                WorkflowSettings.resolve(settings, against: advertised) else { return nil }
        return (setting, value, offered)
    }

    @Test func nothingIsSentWhenTheFileAsksForNothing() {
        #expect(resolved(WorkflowSettings(), [modeOption, modelOption]) == StartOptions.none)
    }

    @Test func aNamedModeIsSentUnderTheIdTheRuntimeAdvertised() {
        let options = resolved(WorkflowSettings(permissionMode: "acceptEdits"), [modeOption, modelOption])
        #expect(options?.values == ["permission_mode": .string("acceptEdits")])
        // Not under "mode", which is what a reimplementation of `ModeMemory`'s rule
        // would most likely have picked.
        #expect(options?.values["mode"] == nil)
    }

    /// **The test that carries the feature.** Every substitution available here is
    /// toward more permission, and the file asked for less on purpose.
    @Test func aModeTheRuntimeDoesNotOfferIsRefusedAndNotSubstituted() {
        let outcome = WorkflowSettings.resolve(WorkflowSettings(permissionMode: "plan"),
                                               against: [modeOption, modelOption])
        guard case .refused(let setting, let value, _) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(setting == WorkflowSettings.Setting.permissionMode)
        #expect(value == "plan")
        // And nothing was resolved in its place — no default, no nearest match, no
        // silently dropped key.
        #expect(resolved(WorkflowSettings(permissionMode: "plan"), [modeOption]) == nil)
    }

    @Test func theRefusalNamesWhatWouldHaveWorked() {
        let refused = refusal(WorkflowSettings(permissionMode: "plan"), [modeOption])
        // In the order the runtime sent them, so the sentence reads as its menu.
        #expect(refused?.offered == ["default", "acceptEdits", "bypassPermissions"])

        let detail = WorkflowSettings.refusalDetail(
            setting: WorkflowSettings.Setting.permissionMode, value: "plan",
            offered: refused?.offered ?? [], runtime: "Claude")
        #expect(detail == "\"plan\" is not a permission mode Claude offers here — it offers default, acceptEdits, bypassPermissions")
    }

    @Test func aRuntimeThatOffersNoModeAtAllRefusesRatherThanIgnores() {
        let refused = refusal(WorkflowSettings(permissionMode: "plan"), [modelOption])
        #expect(refused?.setting == WorkflowSettings.Setting.permissionMode)
        #expect(refused?.offered == [])

        let detail = WorkflowSettings.refusalDetail(
            setting: WorkflowSettings.Setting.permissionMode, value: "plan",
            offered: [], runtime: "Claude")
        #expect(detail == "Claude does not offer a permission mode here at all")
    }

    @Test func theModelIsFoundByCategoryNotByName() {
        let options = resolved(WorkflowSettings(model: "sonnet"), [modeOption, modelOption])
        #expect(options?.values == ["llm": .string("sonnet")])

        let refused = refusal(WorkflowSettings(model: "haiku"), [modelOption])
        #expect(refused?.setting == WorkflowSettings.Setting.model)
        #expect(refused?.offered == ["opus", "sonnet"])
    }
}
