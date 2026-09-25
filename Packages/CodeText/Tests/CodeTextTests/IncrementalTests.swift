@testable import CodeText
import Foundation
import Testing

/// Text an agent is still writing (041 FR-007, research R7).
struct IncrementalTests {
    static func spans(of text: String, id: UUID) async -> [[CodeSpan]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return await Colourer.shared.spans(id: id, lines: 0..<lines.count,
                                           lineStarts: Colourer.lineStarts(of: lines))
    }

    /// Appending a line at a time, the edited tree colours exactly as a fresh parse would.
    @Test func editingInPlaceMatchesAFreshParse() async throws {
        let full = try ColourerTests.sample("sample.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let edited = UUID()
        #expect(await Colourer.shared.parse(id: edited, text: "", language: .swift))
        var text = ""
        for (index, line) in full.enumerated() {
            text += (index == 0 ? "" : "\n") + line
            await Colourer.shared.edit(id: edited, text: text)
            // Checked every tenth line and at the end: each check is a fresh parse.
            guard index % 10 == 0 || index == full.count - 1 else { continue }
            let fresh = UUID()
            #expect(await Colourer.shared.parse(id: fresh, text: text, language: .swift))
            let a = await Self.spans(of: text, id: edited)
            let b = await Self.spans(of: text, id: fresh)
            #expect(a == b, "differs after line \(index + 1)")
            await Colourer.shared.forget(id: fresh)
        }
        await Colourer.shared.forget(id: edited)
    }

    /// An edit in the middle, and one that deletes, also match a fresh parse.
    @Test func editsThatReplaceAndDeleteMatchAFreshParse() async throws {
        let original = try ColourerTests.sample("sample.py")
        let id = UUID()
        #expect(await Colourer.shared.parse(id: id, text: original, language: .python))
        for next in [original.replacingOccurrences(of: "def sell", with: "def sell_all"),
                     original.replacingOccurrences(of: "    @property\n", with: ""),
                     String(original.prefix(original.count / 2))] {
            await Colourer.shared.edit(id: id, text: next)
            let fresh = UUID()
            #expect(await Colourer.shared.parse(id: fresh, text: next, language: .python))
            #expect(await Self.spans(of: next, id: id) == Self.spans(of: next, id: fresh))
            await Colourer.shared.forget(id: fresh)
        }
        await Colourer.shared.forget(id: id)
    }

    /// Text added far below keeps the colour already worked out above it: only windows the
    /// change touched are asked for again.
    @Test @MainActor func colourAboveAChangeIsKept() async throws {
        let base = try ColourerTests.sample("sample.swift")
        let long = Array(repeating: base, count: 6).joined(separator: "\n")  // ~390 lines
        let document = CodeDocument(text: long, language: .swift)
        document.appear(line: 0)
        try await Self.until { !document.spans(line: 5).isEmpty }
        let before = document.spans(line: 5)

        document.update(text: long + "\nlet more = 1")
        // Window 0 (lines 0–199) was not touched, so its colour is there at once.
        #expect(document.spans(line: 5) == before)
        #expect(document.lines.last == "let more = 1")
        document.appear(line: document.lines.count - 1)
        try await Self.until { !document.spans(line: document.lines.count - 1).isEmpty }
    }

    @MainActor
    static func until(_ condition: @MainActor () -> Bool, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try #require(Date() < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
