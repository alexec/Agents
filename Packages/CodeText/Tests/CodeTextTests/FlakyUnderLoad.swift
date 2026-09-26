import Foundation
import Testing

extension Trait where Self == ConditionTrait {
    /// A test that passes alone and fails on a busy machine because it holds a time
    /// budget. Skipped where `CI` is set; `.github/workflows/ci.yml` runs them again on
    /// their own, allowed to fail, with `AGENTS_RUN_FLAKY=1`. Written on the same line as
    /// `@Test`, where `scripts/flaky-tests.sh` finds them. AgentsKit has its own copy.
    ///
    /// Quarantined:
    /// - PerformanceTests.aThirtyMegabyteFileIsPlainAtOnce — a one-second budget, 0.8 s
    ///   alone on an M-series Mac and 6.4 s in a full parallel run.
    static var flakyUnderLoad: Self {
        let environment = ProcessInfo.processInfo.environment
        return .disabled(if: environment["CI"] != nil && environment["AGENTS_RUN_FLAKY"] != "1",
                         "flaky under load; quarantined in CI (see FlakyUnderLoad.swift)")
    }
}
