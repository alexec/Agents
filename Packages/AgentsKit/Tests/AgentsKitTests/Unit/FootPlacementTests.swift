import AgentsKitCore
import Testing

/// Placing the chat at its foot until it rests there (#1287, #2210).
struct FootPlacementTests {
    /// Whether the pane rests after each sample, in turn.
    private func rested(_ samples: [Double], atTheEnd: Bool) -> [Bool] {
        var foot = FootPlacement(atTheEnd: atTheEnd)
        return samples.map { foot.rests(after: $0) }
    }

    /// Three samples running that agree with the one before: four in all.
    @Test func restsAfterThreeSamplesThatAgree() {
        #expect(rested([0, 0, 0.2, 0], atTheEnd: true) == [false, false, false, true])
    }

    /// The bug: after a long read back the move lands turns short of the end, and the
    /// pane sits still there. Still is not enough for going to the end.
    @Test func stillShortOfTheEndIsNotAtRestForGoingToTheEnd() {
        #expect(!rested(Array(repeating: -12_000, count: 10), atTheEnd: true).contains(true))
    }

    /// Opening a chat shorter than its pane rests where it is.
    @Test func stillShortOfTheEndIsAtRestForOpening() {
        #expect(rested([-120, -120, -120, -120], atTheEnd: false) == [false, false, false, true])
    }

    /// Rows measured above the end move it: every move starts the count again.
    @Test func aMovingEndStartsTheCountAgain() {
        #expect(rested([-9_000, -4_000, 0, 0, -600, 0, 0, 0, 0], atTheEnd: true)
            == [false, false, false, false, false, false, false, false, true])
    }

    /// Not yet measured, as when the chat was just chosen.
    @Test func anUnmeasuredSampleNeverRests() {
        #expect(!rested(Array(repeating: -.infinity, count: 5), atTheEnd: false).contains(true))
    }

    @Test func aBounceAtTheEndRestsOnceItIsStill() {
        #expect(rested([30, 12, 3, 0, 0, 0, 0], atTheEnd: true) == [false, false, false, false, false, false, true])
    }
}
