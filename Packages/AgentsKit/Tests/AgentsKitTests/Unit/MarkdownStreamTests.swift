import Foundation
import Testing
@testable import AgentsKitCore

/// A streamed reply is read again at its tail, not from its start, and reads the same
/// (P20261022-18).
@Suite("Reading a growing reply")
struct MarkdownStreamTests {
    private static func reply(_ count: Int) -> String {
        (0..<count).map { index in
            let paragraph = "Paragraph \(index) of the reply, with *some* `marks` in it."
            return index % 25 == 24 ? paragraph + "\n\n```swift\nlet line = \(index)\n\nprint(line)\n```" : paragraph
        }
        .joined(separator: "\n\n")
    }

    /// The cost: a chunk more of a long reply reads a part of it, not all of it again.
    @Test func aGrowingReplyIsReadAtItsTail() {
        let cache = MarkdownCache()
        let text = Self.reply(500)
        _ = cache.blocks(for: text)
        let before = cache.charactersRead
        let longer = text + "\n\nOne paragraph more."
        #expect(cache.blocks(for: longer) == MarkdownBlock.parse(longer))
        #expect(cache.charactersRead - before < 5_000)
    }

    /// Read in parts or whole, the same blocks: for the awkward shapes, and at every line
    /// as one of them arrives.
    @Test func readInPartsIsReadWhole() {
        let filler = String(repeating: "Words enough to fill a part of the reading. ", count: 100)
        let shapes = [
            "# Title\n\n" + filler + "\n\n1. one\n\n2. two\n\nText between.\n\n3. three",
            filler + "\n\n- a\n\n  still a\n\n- b\n\nAfter the list.",
            filler + "\n\n> quoted\n\n> more quoted\n\nNot quoted.",
            filler + "\n\n```\nfenced\n\nwith a blank line\n```\n\nAfter the fence.",
            filler + "\n\n~~~~\n```\n\nstill fenced\n~~~~\n\nOut.",
            filler + "\n\n    indented code\n\n    more of it\n\nProse.",
            filler + "\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter the table.",
            filler + "\n\n---\n\nAfter a rule.\n\n---\n\nAnd another.",
            filler + "\n\nA [link][ref].\n\n" + filler + "\n\n[ref]: https://example.com",
            filler + "\n\n<!-- a comment\n\nover a blank line -->\n\nAfter it.",
            "---\ntitle: front\n\nmatter: yes\n---\n\n" + filler + "\n\nBody.",
            filler + "\n\nSetext\n===\n\n" + filler + "\n\n- [ ] a task\n- [x] done",
        ]
        // All but the three a cut could change (a link by reference, HTML, front matter) are read in parts.
        #expect(shapes.filter { MarkdownBlock.parts($0).count > 1 }.count == shapes.count - 3)
        for shape in shapes {
            #expect(MarkdownCache().blocks(for: shape) == MarkdownBlock.parse(shape), "\(shape.suffix(60))")
            let cache = MarkdownCache()
            let lines = shape.components(separatedBy: "\n")
            for end in lines.indices {
                let prefix = lines[...end].joined(separator: "\n")
                #expect(cache.blocks(for: prefix) == MarkdownBlock.parse(prefix), "\(prefix.suffix(60))")
            }
        }
    }

    /// Every document in this repository's specs reads the same in parts as whole.
    @Test func theSpecsReadTheSameInParts() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let specs = root.appending(path: "specs")
        guard FileManager.default.fileExists(atPath: specs.path) else { return }
        var checked = 0
        let walker = FileManager.default.enumerator(at: specs, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "md", let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            #expect(MarkdownCache().blocks(for: source) == MarkdownBlock.parse(source), "\(url.path)")
            checked += 1
        }
        #expect(checked > 0)
    }
}
