import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// A test that passes alone and fails when the whole suite runs at once on a busy
    /// machine: a real-time race between a fake runtime's turn and the test's own calls,
    /// or a time budget. Skipped where `CI` is set, so the build fails only on real
    /// failures; `.github/workflows/ci.yml` runs them again on their own, allowed to fail,
    /// with `AGENTS_RUN_FLAKY=1`. They always run on a Mac.
    ///
    /// Written on the same line as `@Test`: `scripts/flaky-tests.sh` finds them by that
    /// to build the filter for that step. Take the trait off when the race is fixed.
    ///
    /// Quarantined, each seen failing in full runs on 2026-09-25 and passing alone. What
    /// was seen, not a diagnosis:
    /// - BlockedTests: twoHelpersFinishingGiveOneResumeNamingEach,
    ///   aPersonsPromptEndsTheBlockAndNothingIsSentLater,
    ///   stoppingABlockedAgentStopsItAndNothingIsSentLater,
    ///   archivingABlockedAgentIsNeverUndoneByAResume — the lead's `blocked` report is
    ///   refused because the helper "has already ended".
    /// - BlockedTests.aBlockWhoseWaitsClosedBeforeItsTurnEndedIsResumedWhenItEnds — the
    ///   lead's 900 ms turn is over before the test looks at it.
    /// - WorktreeStartTests.anAgentCanStartInANewWorktreeOnALocalBranch — a launch
    ///   other than the one expected is recorded.
    /// - UnreportedEndingTests.theEndingAPersonsPromptOvertookIsNotAskedAbout — the
    ///   app's one question is never sent.
    /// - WorkflowRestartTests: theDepthCeilingCountsFromTheRestoredRun,
    ///   aChainShortOfTheCeilingCarriesOnFromTheRestoredDepth — the next link neither
    ///   runs nor is refused within 10 s. Worth a look: it may be more than slowness.
    /// - BigContentTests.aMegabyteDiffIsReadQuickly — a 500 ms budget.
    static var flakyUnderLoad: Self {
        let environment = ProcessInfo.processInfo.environment
        return .disabled(if: environment["CI"] != nil && environment["AGENTS_RUN_FLAKY"] != "1",
                         "flaky under load; quarantined in CI (see FlakyUnderLoad.swift)")
    }
}
