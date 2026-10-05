import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// A test that holds a wall-clock budget, which a shared runner cannot promise.
    /// Skipped where `CI` is set; `.github/workflows/slow-tests.yml` runs them again on
    /// their own, allowed to fail, with `AGENTS_RUN_FLAKY=1`. Written on the same line as
    /// `@Test`, where `scripts/flaky-tests.sh` finds them. AgentsKit and CodeText have
    /// their own copies.
    ///
    /// Quarantined:
    /// - BeforeProofTests.aSilentConnectionIsClosedWithinTheIdleTime — expects the 10 s
    ///   idle close no sooner than 8 s after it sees the connection held, but the timer
    ///   starts at accept; on a loaded runner seeing it took over 2 s and the close
    ///   landed inside the 8 s (2026-10-05, run 37247106522). Fix: time the 8 s from the
    ///   connect, then take it out of here.
    static var flakyUnderLoad: Self {
        let environment = ProcessInfo.processInfo.environment
        return .disabled(if: environment["CI"] != nil && environment["AGENTS_RUN_FLAKY"] != "1",
                         "flaky under load; quarantined in CI (see FlakyUnderLoad.swift)")
    }
}
