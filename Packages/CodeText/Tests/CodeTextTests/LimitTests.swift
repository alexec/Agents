@testable import CodeText
import Testing

/// Where colour stops (041 FR-018, research R6; contract invariant 5).
struct LimitTests {
    @Test func theValuesAreTheOnesResearchSettled() {
        #expect(Limits.colourMaxUTF16 == 512 * 1024)
        #expect(Limits.colourMaxLine == 4_000)
        #expect(Limits.wordMarkMaxLine == 1_000)
        #expect(Limits.wordMarkMaxPairs == 200)
        #expect(Limits.foldMinimum == 8)
        #expect(Limits.foldContext == 3)
    }

    @Test func aTooLargeTextIsPlain() {
        let line = String(repeating: "x", count: 100) + "\n"
        let text = String(repeating: line, count: (512 * 1024) / 101 + 1)
        #expect(Limits.plainReason(for: text) == .tooLarge)
    }

    @Test func oneLongLineMakesItPlain() {
        let text = "let a = 1\n" + String(repeating: "a", count: 4_001) + "\nlet b = 2"
        #expect(Limits.plainReason(for: text) == .lineTooLong)
        #expect(Limits.plainReason(for: String(repeating: "a", count: 4_000)) == nil)
    }

    @Test @MainActor func aDocumentPastALimitSaysWhyAndHasNoSpans() async throws {
        let text = String(repeating: "a", count: 5_000)
        let document = CodeDocument(text: text, language: .swift)
        #expect(document.plainBecause == .lineTooLong)
        document.appear(line: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(document.spans(line: 0).isEmpty)
    }

    @Test @MainActor func anUnknownLanguageIsPlainWithoutAReason() {
        let document = CodeDocument(text: String(repeating: "a", count: 5_000), language: nil)
        #expect(document.plainBecause == nil)
    }
}
