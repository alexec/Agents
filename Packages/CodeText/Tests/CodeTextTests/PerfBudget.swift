import Foundation
import Testing

extension Tag {
    @Tag static var perfBudget: Self
}

extension Trait where Self == Tag.List {
    /// A test that measures work against a wall-clock budget (#225). It runs everywhere,
    /// and everything it asserts about the result is asserted everywhere; only the budget
    /// itself waits for `scripts/perf-tests.sh`, which runs these tests on their own with
    /// `AGENTS_RUN_PERF=1`. A budget held while three agents build beside it measures the
    /// load, not the code, so a plain `swift test`, and a merge wave's `test-codetext`, print the
    /// time without holding it.
    ///
    /// Written on the same line as `@Test`, where `scripts/perf-tests.sh` finds them.
    /// AgentsKit has its own copy.
    static var perfBudget: Self { .tags(.perfBudget) }
}

enum PerfBudget {
    /// Whether this run holds the budgets: only the perf check's own run.
    static var held: Bool { ProcessInfo.processInfo.environment["AGENTS_RUN_PERF"] == "1" }

    /// Expects `took` under `budget` in the perf check, and prints it in every run.
    static func expect(_ took: Duration, under budget: Duration, _ what: String,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        print("perf: \(what) took \(took), budget \(budget)")
        guard held else { return }
        #expect(took < budget, "\(what) took \(took)", sourceLocation: sourceLocation)
    }
}
