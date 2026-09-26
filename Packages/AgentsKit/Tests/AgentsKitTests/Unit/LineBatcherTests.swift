import Foundation
import Testing
@testable import AgentsKitCore

/// The Mac's lines wait up to 400 ms, or until a quarter of a megabyte, before they are
/// posted (046, R6).
@Suite("Batching the Mac's lines")
struct LineBatcherTests {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func oneLineWaitsItsWindow() {
        var batcher = LineBatcher()
        #expect(batcher.append("one", now: start) == nil)
        #expect(batcher.takeIfDue(now: start.addingTimeInterval(0.39)) == nil)
        #expect(batcher.takeIfDue(now: start.addingTimeInterval(0.4)) == ["one"])
        #expect(batcher.isEmpty)
        #expect(batcher.deadline == nil)
    }

    @Test func aBurstIsOneBatch() {
        var batcher = LineBatcher()
        for i in 0..<50 { #expect(batcher.append("entry \(i)", now: start.addingTimeInterval(Double(i) * 0.005)) == nil) }
        #expect(batcher.deadline == start.addingTimeInterval(0.4))
        #expect(batcher.takeIfDue(now: start.addingTimeInterval(0.4))?.count == 50)
    }

    @Test func aFullBatchGoesAtOnce() {
        var batcher = LineBatcher()
        let line = String(repeating: "x", count: 100 * 1024)
        #expect(batcher.append(line, now: start) == nil)
        #expect(batcher.append(line, now: start) == nil)
        // The third would take it past 256 KB, so the first two go and the third waits.
        #expect(batcher.append(line, now: start)?.count == 2)
        #expect(batcher.flush()?.count == 1)
    }

    @Test func oneHugeLineIsItsOwnBatch() {
        var batcher = LineBatcher()
        #expect(batcher.append("small", now: start) == nil)
        let huge = String(repeating: "y", count: 300 * 1024)
        #expect(batcher.append(huge, now: start) == ["small"])
        #expect(batcher.flush() == [huge])
    }

    @Test func flushTakesWhateverWaits() {
        var batcher = LineBatcher()
        #expect(batcher.flush() == nil)
        _ = batcher.append("a", now: start)
        #expect(batcher.flush() == ["a"])
    }
}
