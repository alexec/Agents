import Foundation
import Testing
@testable import AgentsKit

@Suite("What a shell has printed, capped")
struct ScrollbackTests {
    @Test func whatGoesInComesOut() {
        var buffer = Scrollback(cap: 1024)
        buffer.append(Data("hello ".utf8))
        buffer.append(Data("world".utf8))
        #expect(String(decoding: buffer.tail, as: UTF8.self) == "hello world")
        #expect(buffer.hasDropped == false)
        #expect(buffer.dropped == 0)
    }

    @Test func theCapDropsFromTheFront() {
        // The end is the part anyone wants after an hour away, so the front goes.
        var buffer = Scrollback(cap: 10)
        buffer.append(Data("0123456789".utf8))
        buffer.append(Data("abcde".utf8))
        #expect(String(decoding: buffer.tail, as: UTF8.self) == "56789abcde")
        #expect(buffer.count == 10)
        #expect(buffer.dropped == 5)
        #expect(buffer.hasDropped)
    }

    @Test func oneWriteLargerThanTheCapKeepsOnlyItsTail() {
        var buffer = Scrollback(cap: 8)
        buffer.append(Data("old".utf8))
        buffer.append(Data("0123456789abcdef".utf8))
        #expect(String(decoding: buffer.tail, as: UTF8.self) == "89abcdef")
        #expect(buffer.count == 8)
        // Everything held before is gone, and so is the front of the new write.
        #expect(buffer.dropped == 3 + (16 - 8))
    }

    @Test func aBufferThatHasDroppedSaysSo() {
        // The pane needs this to avoid implying the replay is the whole session.
        var buffer = Scrollback(cap: 4)
        #expect(buffer.hasDropped == false)
        buffer.append(Data("12345".utf8))
        #expect(buffer.hasDropped)
    }

    @Test func anEmptyAppendChangesNothing() {
        var buffer = Scrollback(cap: 16)
        buffer.append(Data("x".utf8))
        buffer.append(Data())
        #expect(buffer.count == 1)
        #expect(buffer.dropped == 0)
    }

    @Test func theTailCanBeAskedForInPart() {
        var buffer = Scrollback(cap: 100)
        buffer.append(Data("0123456789".utf8))
        #expect(String(decoding: buffer.tail(limit: 4), as: UTF8.self) == "6789")
        // Asking for more than there is gives what there is.
        #expect(String(decoding: buffer.tail(limit: 999), as: UTF8.self) == "0123456789")
    }

    @Test func clearingForgetsTheDropsToo() {
        var buffer = Scrollback(cap: 4)
        buffer.append(Data("12345".utf8))
        buffer.clear()
        #expect(buffer.isEmpty)
        #expect(buffer.dropped == 0)
    }

    @Test func bytesAreKeptExactlyIncludingOnesThatAreNotText() {
        // The buffer never decodes. An escape sequence split across two appends must
        // come back out in one piece and unchanged.
        var buffer = Scrollback(cap: 64)
        buffer.append(Data([0x1B, 0x5B]))
        buffer.append(Data([0x33, 0x31, 0x6D]))
        #expect(Array(buffer.tail) == [0x1B, 0x5B, 0x33, 0x31, 0x6D])
    }
}
