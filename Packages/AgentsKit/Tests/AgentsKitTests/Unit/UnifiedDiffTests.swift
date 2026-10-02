import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Reading what git prints (035 research R4).
@Suite("Reading git's changes")
struct UnifiedDiffTests {
    @Test func hunksWithAndWithoutCounts() {
        #expect(GitChanges.hunkStarts("@@ -1 +1 @@") == (1, 1))
        #expect(GitChanges.hunkStarts("@@ -10,4 +12,6 @@ func x()") == (10, 12))
        #expect(GitChanges.hunkStarts("@@ -0,0 +1,3 @@") == (0, 1))
    }

    @Test func linesAreNumberedInTheNewFile() throws {
        let text = """
        diff --git a/a.swift b/a.swift
        index 1..2 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        """
        let hunks = GitChanges.parseUnified(text)
        try #require(hunks.count == 1)
        #expect(hunks[0].lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(hunks[0].lines.map(\.newLine) == [1, nil, 2, 3])
        try #require(hunks[0].lines.count > 2)
        #expect(hunks[0].lines[2].text == "TWO")
    }

    @Test func noNewlineAtEndIsAFlagNotALine() throws {
        let text = "@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file"
        let hunks = GitChanges.parseUnified(text)
        try #require(!hunks.isEmpty)
        #expect(hunks[0].lines.count == 2)
        #expect(hunks[0].noNewlineAtEnd)
    }

    @Test func anEmptyDiffHasNoHunks() {
        #expect(GitChanges.parseUnified("").isEmpty)
    }

    @Test func numstatReadsBinaryAsNoCounts() {
        let data = Data("3\t1\ta.swift\0-\t-\timage.png\0".utf8)
        let counts = GitChanges.parseNumstat(data)
        #expect(counts["a.swift"]?.added == 3)
        #expect(counts["a.swift"]?.removed == 1)
        #expect(counts["image.png"] != nil)
        #expect(counts["image.png"]?.added == nil)
    }

    @Test func nameStatusPairsLettersWithPaths() {
        let data = Data("M\0a.swift\0A\0dir with space/b.md\0D\0café.txt\0".utf8)
        let status = GitChanges.parseNameStatus(data)
        #expect(status.map(\.path) == ["a.swift", "dir with space/b.md", "café.txt"])
        #expect(status.map(\.status) == ["M", "A", "D"])
    }

    @Test func numstatCountsARenameUnderItsNewPath() {
        let data = Data(("1\t1\t\0old/a.swift\0new/a.swift\0" + "2\t0\tb.md\0").utf8)
        let counts = GitChanges.parseNumstat(data)
        #expect(counts["new/a.swift"]?.added == 1)
        #expect(counts["old/a.swift"] == nil)
        #expect(counts["b.md"]?.added == 2)
    }

    @Test func nameStatusReadsARenameWithBothPaths() {
        let data = Data("R087\0old/a.swift\0new/a.swift\0M\0b.md\0C100\0c.txt\0d.txt\0".utf8)
        let status = GitChanges.parseNameStatus(data)
        #expect(status.map(\.path) == ["new/a.swift", "b.md", "d.txt"])
        #expect(status.map(\.status) == ["R", "M", "A"])
        #expect(status.map(\.oldPath) == ["old/a.swift", nil, nil])
    }

    @Test func anUnknownChangeStateReadsAsAChange() throws {
        let decoded = try JSONDecoder().decode([ChangeState].self, from: Data(#"["renamed","copied"]"#.utf8))
        #expect(decoded == [.renamed, .modified])
    }

    @Test func aBatchAnswerIsReadByItsSizes() {
        let body = "one\ntwo\n"
        let data = Data("abc blob \(body.utf8.count)\n\(body)\nmissing.txt missing\n".utf8)
        let texts = GitChanges.parseBatch(data, paths: ["a.txt", "missing.txt"])
        #expect(texts["a.txt"] == body)
        #expect(texts["missing.txt"] == nil)
    }
}
