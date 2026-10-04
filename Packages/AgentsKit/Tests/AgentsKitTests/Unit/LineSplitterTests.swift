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

    /// The phone's network link and the bridge hand it `Data`, in Wi‑Fi-sized pieces
    /// that are often slices of a bigger buffer. `agents/list` was 5.4 MB on
    /// 2026-09-25; read in 4 KB pieces the old search took seconds on a phone.
    @Test func takesDataSlicesAndLooksAtEachByteOnce() throws {
        let line = Data(repeating: UInt8(ascii: "y"), count: 5 * 1024 * 1024)
        var wire = Data("{\"a\":1}\n".utf8)
        wire.append(line)
        wire.append(Data("\n{\"b\":2}\n".utf8))
        var splitter = LineSplitter()
        var lines: [String] = []
        var offset = wire.startIndex
        while offset < wire.endIndex {
            let end = min(offset + 4096, wire.endIndex)
            splitter.append(wire[offset..<end])
            while let next = splitter.next() { lines.append(next) }
            offset = end
        }
        try #require(lines.count == 3)
        #expect(lines.first == "{\"a\":1}")
        #expect(lines[1].utf8.count == line.count)
        #expect(lines.last == "{\"b\":2}")
        #expect(splitter.examined == wire.count)
    }

    /// A peer that never ends its line is let go once the line passes the limit, and
    /// what it sent is not kept.
    @Test func givesUpOnALineLongerThanItsLimit() {
        var splitter = LineSplitter(maximumLine: 1024)
        let block = [UInt8](repeating: UInt8(ascii: "x"), count: 512)
        #expect(feed(&splitter, block).isEmpty)
        #expect(!splitter.overflowed)
        #expect(feed(&splitter, block + [UInt8(ascii: "x")]).isEmpty)
        #expect(splitter.overflowed)
        // Nothing more is taken, newline or not.
        #expect(feed(&splitter, Array("{\"a\":1}\n".utf8)).isEmpty)
    }

    /// Lines under the limit go through however many there are and however they
    /// arrive, including a read longer than the limit made of short lines.
    @Test func passesLinesUnderItsLimit() {
        var splitter = LineSplitter(maximumLine: 16)
        let wire = Array(String(repeating: "{\"a\":1}\n", count: 20).utf8)
        #expect(feed(&splitter, wire).count == 20)
        #expect(!splitter.overflowed)
        let split = Array("{\"b\":2}".utf8)
        #expect(feed(&splitter, Array(split[..<3])).isEmpty)
        #expect(feed(&splitter, Array(split[3...]) + [UInt8(ascii: "\n")]) == ["{\"b\":2}"])
        #expect(!splitter.overflowed)
    }
}

/// A splitter that cuts long lines (#209): a runtime's or a window's, ours but saying
/// whatever its tools say. A line past the limit is not held, and the lines after it
/// still come through.
@Suite("Line splitter cutting long lines")
struct LineSplitterCutTests {
    private func feed(_ splitter: inout LineSplitter, _ bytes: [UInt8]) -> [String] {
        bytes.withUnsafeBufferPointer { splitter.append($0) }
        var lines: [String] = []
        while let line = splitter.next() { lines.append(line) }
        return lines
    }

    @Test func aLongLineIsCutToAStandInAndTheNextLinesStillCome() throws {
        var splitter = LineSplitter(maximumLine: 1024, cutsLongLines: true)
        let long = Array(#"{"jsonrpc":"2.0","id":7,"result":""#.utf8)
            + [UInt8](repeating: UInt8(ascii: "x"), count: 10_000) + Array("\"}".utf8)
        var lines = feed(&splitter, Array("{\"a\":1}\n".utf8))
        // Read in pieces, as a pipe gives it.
        for piece in stride(from: 0, to: long.count, by: 700) {
            lines += feed(&splitter, Array(long[piece..<min(long.count, piece + 700)]))
        }
        lines += feed(&splitter, Array("\n{\"b\":2}\n".utf8))
        try #require(lines.count == 3)
        #expect(lines.first == "{\"a\":1}")
        #expect(lines.last == "{\"b\":2}")
        #expect(!splitter.overflowed)
        let cut = try JSONRPCCodec.decode(line: lines[1])
        guard case .notification(let method, let params) = cut else {
            Issue.record("the stand-in is a notification: \(cut)")
            return
        }
        #expect(method == LineSplitter.cutMethod)
        #expect(params?["bytes"]?.intValue == long.count)
        #expect(params?["start"]?.stringValue?.hasPrefix(#"{"jsonrpc":"2.0","id":7"#) == true)
        #expect((params?["start"]?.stringValue?.utf8.count ?? .max) <= LineSplitter.cutStartKept)
    }

    /// What is held while a line is being cut is its first bytes, not the line.
    @Test func whatIsHeldStaysSmall() {
        var splitter = LineSplitter(maximumLine: 1024, cutsLongLines: true)
        let block = [UInt8](repeating: UInt8(ascii: "x"), count: 64 * 1024)
        for _ in 0..<64 { #expect(feed(&splitter, block).isEmpty) }
        let lines = feed(&splitter, Array("\n".utf8))
        #expect(lines.count == 1)
        #expect(lines.first?.contains(LineSplitter.cutMethod) == true)
        #expect(lines.first?.contains("\(64 * 64 * 1024)") == true)
    }
}
