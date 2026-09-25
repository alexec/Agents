@testable import CodeText
import Foundation
import Testing

/// Colouring real-looking code in every vendored language (041 FR-001, FR-006, SC-006;
/// contract invariant 1).
struct ColourerTests {
    /// Each vendored language and its sample file.
    static let samples: [(CodeLanguage, String)] = [
        (.swift, "sample.swift"), (.python, "sample.py"), (.javascript, "sample.js"),
        (.typescript, "sample.ts"), (.tsx, "sample.tsx"), (.json, "sample.json"),
        (.markdown, "sample.md"),
    ]

    static func sample(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil,
                                                 subdirectory: "Samples"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every line's spans, the whole text at once.
    static func colour(_ text: String, as language: CodeLanguage) async throws -> [[CodeSpan]] {
        let id = UUID()
        let ok = await Colourer.shared.parse(id: id, text: text, language: language)
        try #require(ok, "\(language) did not parse")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let spans = await Colourer.shared.spans(id: id, lines: 0..<lines.count,
                                                lineStarts: Colourer.lineStarts(of: lines))
        await Colourer.shared.forget(id: id)
        return spans
    }

    @Test(arguments: samples)
    func everyVendoredLanguageHasASample(language: CodeLanguage, file: String) throws {
        #expect(Grammar.language(for: language) != nil)
        #expect(try !Self.sample(file).isEmpty)
    }

    @Test(arguments: samples)
    func spansStayInsideTheirLineAndNeverOverlap(language: CodeLanguage, file: String) async throws {
        let text = try Self.sample(file)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let spans = try await Self.colour(text, as: language)
        #expect(spans.count == lines.count)
        #expect(spans.contains { !$0.isEmpty }, "\(language) coloured nothing")
        for (line, lineSpans) in zip(lines, spans) {
            var end = 0
            for span in lineSpans.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                #expect(span.range.lowerBound >= end, "overlap in \(language): \(line)")
                #expect(span.range.upperBound <= line.utf16.count)
                #expect(span.role != .plain)
                end = span.range.upperBound
            }
        }
    }

    /// Colour never changes the text: the styled lines, joined, are the file.
    @Test(arguments: samples)
    func theTextIsUntouched(language: CodeLanguage, file: String) async throws {
        let text = try Self.sample(file)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let spans = try await Self.colour(text, as: language)
        var marked = AttributeContainer()
        marked.link = URL(string: "https://example.com")
        let rebuilt = zip(lines, spans).map { line, lineSpans in
            String(CodeText.attributed(line, spans: lineSpans, style: { _ in marked },
                                       marks: [0..<3], mark: marked).characters)
        }.joined(separator: "\n")
        #expect(rebuilt == text)
    }

    @Test func theSwiftSampleHasEveryMainRole() async throws {
        let spans = try await Self.colour(Self.sample("sample.swift"), as: .swift)
        let roles = Set(spans.joined().map(\.role))
        for role in [CodeRole.keyword, .string, .comment, .number, .type, .function] {
            #expect(roles.contains(role), "no \(role) in the Swift sample")
        }
    }

    /// What a few well-known stretches are, read back from the Swift sample.
    @Test func theSwiftSampleReadsRight() async throws {
        let text = try Self.sample("sample.swift")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let spans = try await Self.colour(text, as: .swift)
        func role(of word: String, onLineContaining marker: String) -> CodeRole? {
            guard let index = lines.firstIndex(where: { $0.contains(marker) }),
                  let range = lines[index].range(of: word) else { return nil }
            let at = lines[index].utf16.distance(from: lines[index].startIndex, to: range.lowerBound)
            return spans[index].last { $0.range.contains(at) }?.role
        }
        #expect(role(of: "struct", onLineContaining: "struct Till {") == .keyword)
        #expect(role(of: "coffee", onLineContaining: "till.sell(\"coffee\"") == .string)
        #expect(role(of: "A small shop", onLineContaining: "A small shop") == .comment)
        #expect(role(of: "150.00", onLineContaining: "150.00") == .number)
        #expect(role(of: "Decimal", onLineContaining: "var float: Decimal") == .type)
    }

    /// A file half written, cut in the middle of a string, still colours what is there.
    @Test(arguments: samples)
    func halfWrittenCodeStillColours(language: CodeLanguage, file: String) async throws {
        let text = try Self.sample(file)
        let cut = String(text.prefix(text.count * 2 / 3)) + "\"unterminated"
        let spans = try await Self.colour(cut, as: language)
        #expect(spans.contains { !$0.isEmpty })
    }

    @Test func aLanguageWithoutAGrammarDoesNotParse() async {
        #expect(await !Colourer.shared.parse(id: UUID(), text: "SELECT 1", language: .go))
    }

    @Test func layingASpanOverOthersTrimsThem() {
        var spans = [CodeSpan(range: 0..<10, role: .string)]
        Colourer.lay(CodeSpan(range: 3..<5, role: .keyword), over: &spans)
        #expect(spans == [CodeSpan(range: 0..<3, role: .string),
                          CodeSpan(range: 3..<5, role: .keyword),
                          CodeSpan(range: 5..<10, role: .string)])
    }
}
