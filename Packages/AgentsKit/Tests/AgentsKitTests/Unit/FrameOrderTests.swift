import Foundation
import Testing
@testable import AgentsKitCore

/// Frames come out by number, each once, whatever order iCloud hands them over in (046).
@Suite("Putting relayed frames in order")
struct FrameOrderTests {
    let session = UUID()
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func frame(_ seq: Int64) -> Frame {
        Frame(session: session, direction: .toDevice, seq: seq, lines: ["line \(seq)"])
    }

    private func seqs(_ frames: [Frame]) -> [Int64] { frames.map(\.seq) }

    @Test func inOrderIsHandedOnAtOnce() {
        var order = FrameOrder()
        #expect(seqs(order.accept(frame(0), now: start)) == [0])
        #expect(seqs(order.accept(frame(1), now: start)) == [1])
        #expect(order.next == 2)
    }

    @Test func reversedIsHeldThenHandedOnInOrder() {
        var order = FrameOrder()
        #expect(order.accept(frame(2), now: start).isEmpty)
        #expect(order.accept(frame(1), now: start).isEmpty)
        #expect(seqs(order.accept(frame(0), now: start)) == [0, 1, 2])
    }

    @Test func aRepeatIsDropped() {
        var order = FrameOrder()
        _ = order.accept(frame(0), now: start)
        #expect(order.accept(frame(0), now: start).isEmpty)
        _ = order.accept(frame(2), now: start)
        #expect(order.accept(frame(2), now: start).isEmpty)
        #expect(seqs(order.accept(frame(1), now: start)) == [1, 2])
    }

    @Test func aGapFilledLateIsNotAGap() {
        var order = FrameOrder()
        _ = order.accept(frame(1), now: start)
        #expect(!order.gapExpired(now: start.addingTimeInterval(9)))
        #expect(seqs(order.accept(frame(0), now: start.addingTimeInterval(9))) == [0, 1])
        #expect(!order.gapExpired(now: start.addingTimeInterval(60)))
    }

    @Test func aGapLeftForTenSecondsEndsIt() {
        var order = FrameOrder()
        _ = order.accept(frame(1), now: start)
        _ = order.accept(frame(2), now: start.addingTimeInterval(5))
        #expect(!order.gapExpired(now: start.addingTimeInterval(10)))
        #expect(order.gapExpired(now: start.addingTimeInterval(10.5)))
    }
}
