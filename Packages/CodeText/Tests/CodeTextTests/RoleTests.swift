@testable import CodeText
import Foundation
import Testing

/// Capture names to the nine roles (041 research R4).
struct RoleTests {
    @Test(arguments: [
        ("keyword.return", CodeRole.keyword), ("keyword", .keyword),
        ("string.special", .string), ("string", .string),
        ("comment.documentation", .comment),
        ("number", .number), ("constant.builtin", .number), ("boolean", .number),
        ("type.builtin", .type), ("constructor", .type),
        ("function.method", .function), ("function.call", .function),
        ("property", .property), ("attribute", .property),
        ("operator", .punctuation), ("punctuation.bracket", .punctuation),
        ("variable.builtin", .keyword),
        ("variable", .plain), ("variable.parameter", .plain), ("label", .plain), ("", .plain),
        ("something.invented.later", .plain),
    ])
    func aCaptureMapsToItsRole(name: String, expected: CodeRole) {
        #expect(CodeRole.role(forCapture: name) == expected)
    }

    /// Every capture every vendored query uses maps to something, and the ones a reader
    /// cares about most are not lost to plain.
    @Test func everyVendoredCaptureMaps() throws {
        var names: Set<String> = []
        let pattern = try NSRegularExpression(pattern: #"@([A-Za-z_][\w.\-]*)"#)
        let vendored = CodeLanguage.allCases.filter { Grammar.language(for: $0) != nil }
        #expect(!vendored.isEmpty)
        for language in vendored {
            let text = try #require(Grammar.queryText(for: language), "\(language) has no query")
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
            }
        }
        for name in names where name.hasPrefix("keyword") || name.hasPrefix("string")
            || name.hasPrefix("comment") || name.hasPrefix("function") {
            #expect(CodeRole.role(forCapture: name) != .plain, "\(name) went to plain")
        }
    }
}
