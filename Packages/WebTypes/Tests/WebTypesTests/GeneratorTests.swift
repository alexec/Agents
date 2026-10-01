import Foundation
import Testing
@testable import WebTypesKit

@Suite("Web types generator")
struct GeneratorTests {
    static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyInputExistsAndParses() throws {
        let files = try Generator(root: Self.repo).parse()
        #expect(files.contains { $0.path.hasSuffix("AgentsKitCore/Daemon/DaemonAPI.swift") })
        #expect(files.contains { $0.path.hasSuffix("AgentsKitCore/Control/Grant.swift") })
        #expect(files.contains { $0.path.contains("AgentsKitCore/Model/") })
        for file in files { #expect(!file.syntax.hasError, "\(file.path) does not parse") }
    }

    @Test func theSameSourceGivesTheSameBytes() throws {
        let generator = Generator(root: Self.repo)
        #expect(try generator.generate() == generator.generate())
    }

    @Test func aMissingInputFails() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "webtypes-\(UUID().uuidString)")
        #expect(throws: Generator.Failure.self) { try Generator(root: empty).generate() }
    }

    @Test func staleNamesTheFirstDifferingLine() {
        let message = Freshness.message(current: "a\nb\nc\n", made: "a\nB\nc\n")
        #expect(message.contains("line 2 is:    b"))
        #expect(message.contains("and should be: B"))
        #expect(Freshness.message(current: nil, made: "x").contains("is missing"))
    }
}
