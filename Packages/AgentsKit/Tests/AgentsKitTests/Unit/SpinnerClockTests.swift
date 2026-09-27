import Foundation
import Testing
@testable import AgentsKitCore

/// Every spinner reads its step off the clock, so two drawn at the same instant agree
/// however long each has been on screen.
@Suite("Spinners turn together")
struct SpinnerClockTests {
    @Test("The same instant gives the same step, whenever the spinner appeared")
    func sameInstantSameStep() {
        let now = Date(timeIntervalSinceReferenceDate: 812_345_678.37)
        // Nothing about the view goes in: only the date. Two calls are two spinners.
        #expect(SpinnerClock.step(at: now, spokes: 12) == SpinnerClock.step(at: now, spokes: 12))
        #expect(SpinnerClock.step(at: now, spokes: 12) == 4)
    }

    @Test("A step lasts one tick, and a full period comes back round")
    func ticks() {
        let start = SpinnerClock.epoch.addingTimeInterval(1000)
        for spokes in [8, 12] {
            let tick = SpinnerClock.tick(spokes: spokes)
            for n in 0..<spokes {
                // The middle of each tick, clear of floating-point edges.
                let date = start.addingTimeInterval((Double(n) + 0.5) * tick)
                #expect(SpinnerClock.step(at: date, spokes: spokes) == n)
                #expect(SpinnerClock.step(at: date.addingTimeInterval(SpinnerClock.period), spokes: spokes) == n)
            }
        }
    }

    @Test("A date before the epoch still lands in range")
    func beforeEpoch() {
        for offset in stride(from: -3.0, to: 0, by: 0.07) {
            let step = SpinnerClock.step(at: SpinnerClock.epoch.addingTimeInterval(offset), spokes: 8)
            #expect((0..<8).contains(step))
        }
    }

    @Test("The lit spoke is full, the tail fades behind it and never vanishes")
    func tail() {
        let spokes = 12
        let step = 3
        #expect(SpinnerClock.opacity(ofSpoke: step, step: step, spokes: spokes) == 1)
        // Walking backwards from the lit spoke, each is fainter than the one before,
        // wrapping past zero.
        var last = 1.0
        for behind in 1..<spokes {
            let spoke = (step - behind + spokes) % spokes
            let opacity = SpinnerClock.opacity(ofSpoke: spoke, step: step, spokes: spokes)
            #expect(opacity < last)
            #expect(opacity >= SpinnerClock.faintest)
            last = opacity
        }
    }
}
