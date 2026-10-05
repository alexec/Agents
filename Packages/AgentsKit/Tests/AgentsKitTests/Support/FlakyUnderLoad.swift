import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// A test that holds a wall-clock budget, which a shared runner cannot promise.
    /// Skipped where `CI` is set, or `AGENTS_QUARANTINE=1`, which
    /// `scripts/build-cache.sh swift test` sets unless it is already set (`AGENTS_QUARANTINE=0`
    /// runs them); so a run fails only on real failures.
    /// `.github/workflows/slow-tests.yml` runs them again on their own, allowed to fail,
    /// with `AGENTS_RUN_FLAKY=1`.
    ///
    /// Not for a race. A test that races a fake runtime's turn holds the turn with a
    /// `TurnGate` instead, and one that acts as soon as an agent's turn ends waits with
    /// `settled`, past the question about a silent ending (2026-09-26).
    ///
    /// Written on the same line as `@Test`: `scripts/flaky-tests.sh` finds them by that
    /// to build the filter for that step.
    ///
    /// Not for a performance budget either: a test that measures work against the clock
    /// is `.perfBudget` (PerfBudget.swift), and only `scripts/perf-tests.sh` holds it to
    /// the budget (#225). The 50 ms reconcile, the megabyte diff, the 6,000-entry folder
    /// and the 200-file changes list moved there.
    ///
    /// Quarantined:
    /// - SSHMasterTests.aMasterThatDiesIsNoticedWithinASecond — 1 s.
    /// - LinkChooserTests.aQuietDirectLinkLosesAfterTheWindow — 4 s; took 35 s on the
    ///   runner 2026-09-26, still choosing the relay.
    /// - AttentionTests.theSettlingPauseIsNotStartedAgainByARestart — a 2 s pause, 1.5 s
    ///   slept through it, and delivery looked for within the next 1 s.
    /// - PoolSwitchTests.copilotMonthlyQuotaInChatMovesToTheNextRuntime and
    ///   copilotQuotaWithPoolOffStopsWithoutClaimingSuccess — quota handling timed out
    ///   after 10 s in full local runs; the PoolSwitch suite passed in isolation. Keep
    ///   them out of the main CI run and run them with the quarantine step in CI.
    /// - PoolSwitchTests.anotherChatOnTheSpentRuntimeMovesBeforeItsNextTurn — takes two
    ///   turns and waits up to 30 s for the first chat's report before the second starts;
    ///   the suite was still running at the 10-minute CI cutoff (2026-09-28).
    ///
    /// Slow quarantine, run manually from `.github/workflows/slow-tests.yml`:
    /// - RelayCarryingTests.aReplyOfFiveMegabytesArrivesWhole — 62 s on the shared
    ///   runner in a completed run; stalled for over 5 min in a later loaded run.
    /// - RelayCarryingTests.aBusyTurnIsAFewPostsASecond — 329 s on the shared runner.
    /// - RebuiltServerTests.aWipedServerIsSetUpAgainWithoutAsking — took 322 s on the
    ///   shared runner before failing to observe the rebuilt server's connected state.
    /// - CredentialStoreTests.replacingKeepsOnlyTheNewOne — 45 s writing twice to the
    ///   real login Keychain in a completed CI run.
    static var flakyUnderLoad: Self {
        let environment = ProcessInfo.processInfo.environment
        return .disabled(if: (environment["CI"] != nil || environment["AGENTS_QUARANTINE"] == "1")
                         && environment["AGENTS_RUN_FLAKY"] != "1",
                         "flaky under load; quarantined in CI (see FlakyUnderLoad.swift)")
    }

    /// A slow test that does not belong on the main CI path. Run it with
    /// `AGENTS_RUN_SLOW=1` through `.github/workflows/slow-tests.yml`.
    static var slowUnderLoad: Self {
        let environment = ProcessInfo.processInfo.environment
        return .disabled(if: (environment["CI"] != nil || environment["AGENTS_QUARANTINE"] == "1")
                         && environment["AGENTS_RUN_SLOW"] != "1",
                         "slow under load; quarantined from main CI")
    }
}
