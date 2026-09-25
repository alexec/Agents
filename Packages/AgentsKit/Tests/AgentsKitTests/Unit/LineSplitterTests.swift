import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Line splitter")
struct LineSplitterTests {
    private func feed(_ splitter: inout LineSplitter, _ bytes: [UInt8]) -> [String] {
        bytes.withUnsafeBufferPointer { splitter.append($0) }
        var lines: [String] = []
        while let line = splitter.next() { lines.append(line) }
        return lines
    }

    @Test func splitsOnNewlinesAcrossReads() {
        var splitter = LineSplitter()
        #expect(feed(&splitter, Array("{\"a\":1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(feed(&splitter, Array(":2}\r\n\n  \n{\"c\":3}\n".utf8)) == ["{\"b\":2}", "{\"c\":3}"])
        #expect(feed(&splitter, Array("  {\"d\":4}  ".utf8)).isEmpty)
        #expect(feed(&splitter, Array("\n".utf8)) == ["{\"d\":4}"])
    }

    @Test func keepsMultibyteCharactersSplitAcrossReads() {
        var splitter = LineSplitter()
        let bytes = Array("héllo — ✓\n".utf8)
        var lines: [String] = []
        for byte in bytes { lines += feed(&splitter, [byte]) }
        #expect(lines == ["héllo — ✓"])
    }

    /// A twenty-megabyte page, read the way the socket reads it. The old loop searched
    /// the whole backlog after every read: about 3,300 MB looked at for 20 MB of line.
    @Test func looksAtEachByteOnceForALongLine() {
        let size = 20 * 1024 * 1024
        let chunk = 64 * 1024
        var splitter = LineSplitter()
        let block = [UInt8](repeating: UInt8(ascii: "x"), count: chunk)
        var lines: [String] = []
        for _ in 0..<(size / chunk) { lines += feed(&splitter, block) }
        lines += feed(&splitter, [UInt8(ascii: "\n")])
        #expect(lines.count == 1)
        #expect(lines.first?.utf8.count == size)
        #expect(splitter.examined == size + 1)
    }

    @Test func looksAtEachByteOnceForManyShortLines() {
        var splitter = LineSplitter()
        var total = 0
        var count = 0
        for i in 0..<50_000 {
            let bytes = Array("{\"i\":\(i)}\n".utf8)
            total += bytes.count
            count += feed(&splitter, bytes).count
        }
        #expect(count == 50_000)
        #expect(splitter.examined == total)
    }
}
