import Foundation
import Testing
@testable import WebTypesKit

/// The checked-in Web/src/protocol/generated.ts is what the Swift source makes now (071,
/// FR-035, SC-006). A protocol type changed in Swift without regenerating fails here, in CI
/// on every pull request and push, and in scripts/web.sh check.
@Suite("Generated types are fresh")
struct GeneratedIsFreshTests {
    @Test func theCheckedInTypesAreWhatTheSourceMakes() throws {
        let generator = Generator(root: GeneratorTests.repo)
        let made = try generator.generate()
        let current = try? String(contentsOf: GeneratorTests.repo.appending(path: Generator.output), encoding: .utf8)
        #expect(current == made, Comment(rawValue: Freshness.message(current: current, made: made)))
    }
}
