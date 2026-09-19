import Foundation
import SwiftTerm
import Testing
@testable import AgentsKit

/// The property `shell.attach` rests on.
///
/// A pty splits its output wherever it likes. The daemon keeps raw bytes and the window
/// replays them into its own emulator, so that replay is only correct if the screen
/// depends on the bytes and not on how they were chunked. These tests say it does,
/// against output captured from real programs rather than against invented streams.
///
/// Emulation itself is SwiftTerm's and is not retested here. What is tested is the one
/// thing this design assumes about it.
@Suite("Replaying a shell's output")
struct ReplayTests {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func screen(of terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
        }
    }

    private func feed(_ bytes: [UInt8], inChunksOf size: Int?, rows: Int = 24, cols: Int = 80) -> [String] {
        let terminal = Terminal(delegate: Sink())
        terminal.resize(cols: cols, rows: rows)
        if let size {
            var index = 0
            while index < bytes.count {
                let end = min(index + size, bytes.count)
                terminal.feed(byteArray: Array(bytes[index..<end]))
                index = end
            }
        } else {
            terminal.feed(byteArray: bytes)
        }
        return screen(of: terminal)
    }

    private func fixture(_ name: String) throws -> [UInt8] {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()   // Unit
            .deletingLastPathComponent()   // AgentsKitTests
            .appending(path: "Fixtures/terminal/\(name)")
        return try Array(Data(contentsOf: url))
    }

    static let captures = ["vim.raw", "less.raw", "top.raw", "colours.raw"]

    @Test(arguments: captures)
    func oneChunkAndOneByteAtATimeGiveTheSameScreen(name: String) throws {
        let bytes = try fixture(name)
        #expect(bytes.isEmpty == false, "fixture \(name) is empty")
        let whole = feed(bytes, inChunksOf: nil)
        let single = feed(bytes, inChunksOf: 1)
        #expect(whole == single, "chunking changed the screen for \(name)")
    }

    @Test(arguments: captures)
    func awkwardChunkSizesChangeNothing(name: String) throws {
        // Sizes chosen to land inside escape sequences and inside UTF-8 characters.
        let bytes = try fixture(name)
        let reference = feed(bytes, inChunksOf: nil)
        for size in [2, 3, 7, 13, 64, 1024] {
            #expect(feed(bytes, inChunksOf: size) == reference,
                    "chunks of \(size) changed the screen for \(name)")
        }
    }

    @Test func aStreamSplitInsideAnEscapeSequenceStillLands() {
        // The narrow case, written out plainly: the CSI is cut in half.
        let bytes = Array("\u{1B}[2J\u{1B}[5;3Hplaced".utf8)
        #expect(feed(bytes, inChunksOf: 1) == feed(bytes, inChunksOf: nil))
        let screen = feed(bytes, inChunksOf: 1)
        #expect(screen[4].hasSuffix("placed"))
    }

    @Test func aStreamSplitInsideAUTF8CharacterStillLands() {
        let bytes = Array("costs £12 and €13".utf8)
        let single = feed(bytes, inChunksOf: 1)
        #expect(single == feed(bytes, inChunksOf: nil))
        #expect(single[0].contains("£12"))
        #expect(single[0].contains("€13"))
    }

    @Test func theAlternateScreenSurvivesBeingChunked() throws {
        // vim and less live on the alternate buffer, so this is the case that matters
        // most for a pane that attaches while one of them is running.
        let bytes = try fixture("vim.raw")
        #expect(feed(bytes, inChunksOf: 1) == feed(bytes, inChunksOf: nil))
    }

    @Test func whatTheScrollbackKeptIsWhatTheEmulatorIsFed() throws {
        // The daemon's buffer and the window's emulator, end to end: bytes appended in
        // arbitrary pieces come back out as one stream that replays identically.
        let bytes = try fixture("colours.raw")
        var buffer = Scrollback(cap: 1024 * 1024)
        var index = 0
        for size in [1, 5, 17, 64] {
            let end = min(index + size, bytes.count)
            guard index < end else { break }
            buffer.append(Data(bytes[index..<end]))
            index = end
        }
        if index < bytes.count { buffer.append(Data(bytes[index...])) }
        #expect(Array(buffer.tail) == bytes)
        #expect(feed(Array(buffer.tail), inChunksOf: nil) == feed(bytes, inChunksOf: nil))
    }
}
