import Foundation
import Testing
@testable import WebTypesKit

/// The checked-in Web/src/protocol/generated.ts is what the Swift source makes now (071,
/// FR-035, SC-006). A pull request need not regenerate it (#473): main regenerates and
/// commits it after the merge (web-dist.yml), so this runs only with AGENTS_WEB_FRESHNESS=1.
/// scripts/web.sh check runs the generator's own --check instead.
@Suite("Generated types are fresh")
struct GeneratedIsFreshTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTS_WEB_FRESHNESS"] == "1",
                   "main regenerates generated.ts after a merge; set AGENTS_WEB_FRESHNESS=1 to check"))
    func theCheckedInTypesAreWhatTheSourceMakes() throws {
        let generator = Generator(root: GeneratorTests.repo)
        let made = try generator.generate()
        let current = try? String(contentsOf: GeneratorTests.repo.appending(path: Generator.output), encoding: .utf8)
        #expect(current == made, Comment(rawValue: Freshness.message(current: current, made: made)))
    }
}
