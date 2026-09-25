@testable import CodeText
import Foundation
import Testing

/// How soon colour arrives, and how soon a text too big for it is shown plain
/// (041 SC-001, SC-005). Timed limits hold only in an optimised build, where the
/// grammars are compiled as they ship; a debug run records the times and checks
/// nothing about them.
struct PerformanceTests {
    /// A 5,000-line Swift file: the samples repeated.
    static func fiveThousandLines() throws -> String {
        let sample = try ColourerTests.sample("sample.swift")
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        while out.count < 5_000 { out += lines }
        return out.prefix(5_000).joined(separator: "\n")
    }

    /// From the text to the first screen coloured: the parse, then the first window.
    @Test @MainActor func theFirstScreenOfAFiveThousandLineFileIsColouredQuickly() async throws {
        let text = try Self.fiveThousandLines()
        // The query is compiled once a process; warm it, as any earlier Swift file would.
        _ = await Grammar.query(for: .swift)
        let start = ContinuousClock.now
        let document = CodeDocument(text: text, language: .swift)
        document.appear(line: 0)
        try await IncrementalTests.until({ !document.spans(line: 5).isEmpty }, seconds: 10)
        let elapsed = ContinuousClock.now - start
        print("041 SC-001: first coloured screen of 5,000 Swift lines in \(elapsed)")
        #if !DEBUG
        #expect(elapsed < .milliseconds(500))
        #endif
    }

    @Test @MainActor func aOneLineMinifiedFileIsPlainAtOnce() throws {
        let line = (0..<8_000).map { "var a\($0)=function(b){return b+\($0)}" }.joined(separator: ";")
        let start = ContinuousClock.now
        let document = CodeDocument(text: line, language: .javascript)
        let elapsed = ContinuousClock.now - start
        print("041 SC-005: \(line.utf16.count / 1024) KB on one line judged plain in \(elapsed)")
        #expect(document.plainBecause == .lineTooLong)
        #expect(elapsed < .seconds(1))
    }

    @Test @MainActor func aThirtyMegabyteFileIsPlainAtOnce() throws {
        let row = #"{"id": 1, "name": "item", "tags": ["a", "b"], "price": 12.5, "ok": true},"# + "\n"
        let text = "[\n" + String(repeating: row, count: 31 * 1024 * 1024 / row.utf8.count) + "]"
        let start = ContinuousClock.now
        let document = CodeDocument(text: text, language: .json)
        let elapsed = ContinuousClock.now - start
        print("041 SC-005: \(text.utf8.count / 1_048_576) MB judged plain in \(elapsed)")
        #expect(document.plainBecause == .tooLarge)
        #expect(elapsed < .seconds(1))
    }
}
