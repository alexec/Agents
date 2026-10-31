import Testing
@testable import AgentsKitCore

/// #2753: a held dictate button sends where it was let go, cancels when dragged away, and
/// the send waits for the last words.
@Suite("Push to talk")
struct PushToTalkPressTests {
    @Test func heldAndLetGoInPlaceSends() {
        var press = PushToTalkPress()
        press.moved(by: 2, 3)
        let started = press.held()
        #expect(started)
        let ending = press.ended(at: 4, 4)
        #expect(ending == .send)
    }

    @Test func heldAndDraggedAwayCancels() {
        var press = PushToTalkPress()
        let started = press.held()
        #expect(started)
        press.moved(by: 0, -80)
        #expect(press.isDraggedOff)
        let ending = press.ended(at: 0, -80)
        #expect(ending == .cancel)
    }

    @Test func draggedBackBeforeLettingGoSends() {
        var press = PushToTalkPress()
        let started = press.held()
        #expect(started)
        press.moved(by: 60, 0)
        press.moved(by: 10, 0)
        let ending = press.ended(at: 10, 0)
        #expect(ending == .send)
    }

    @Test func aDragJustUnderTheDistanceStillSends() {
        var press = PushToTalkPress()
        let started = press.held()
        #expect(started)
        let ending = press.ended(at: 30, 40)
        #expect(ending == .send)
    }

    @Test func draggedOffBeforeTheHoldNeverStarts() {
        var press = PushToTalkPress()
        press.moved(by: 70, 0)
        let started = press.held()
        #expect(!started)
        let ending = press.ended(at: 70, 0)
        #expect(ending == nil)
    }

    @Test func aTapIsLeftToTheButton() {
        var press = PushToTalkPress()
        let ending = press.ended(at: 0, 0)
        #expect(ending == nil)
    }

    @Test func eachPressStartsAfresh() {
        var press = PushToTalkPress()
        let started = press.held()
        #expect(started)
        _ = press.ended(at: 90, 0)
        #expect(press == PushToTalkPress())
        let next = press.ended(at: 0, 0)
        #expect(next == nil)
    }

    @Test func waitingForWorkThatFinishesInTime() async {
        let inTime = await waitAtMost(.seconds(5)) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(inTime)
    }

    @Test func waitingStopsAtTheLimit() async {
        let clock = ContinuousClock()
        let started = clock.now
        let inTime = await waitAtMost(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(30))
        }
        #expect(!inTime)
        #expect(clock.now - started < .seconds(10))
    }
}
