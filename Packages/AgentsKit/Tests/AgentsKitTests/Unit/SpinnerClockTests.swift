import Foundation
import Testing
@testable import AgentsKitCore

/// Every spinner reads its angle off the clock, so two drawn at the same instant agree
/// however long each has been on screen.
@Suite("Spinners turn together")
struct SpinnerClockTests {
    @Test("The same instant gives the same angle, whenever the spinner appeared")
    func sameInstantSameAngle() {
        let first = Date(timeIntervalSinceReferenceDate: 812_345_678.25)
        let second = Date(timeIntervalSince1970: first.timeIntervalSince1970)
        // Nothing about the view goes in: only the date. Two calls are two spinners.
        #expect(SpinnerClock.angle(at: first) == SpinnerClock.angle(at: second))
        #expect(abs(SpinnerClock.angle(at: first) - 90) < 0.001)
    }

    @Test("The notch glides through a turn, and a full period comes back round")
    func glides() {
        let start = SpinnerClock.epoch.addingTimeInterval(1000)
        for n in 0..<10 {
            let date = start.addingTimeInterval(Double(n) / 10 * SpinnerClock.period)
            #expect(abs(SpinnerClock.angle(at: date) - Double(n) * 36) < 0.001)
            let later = date.addingTimeInterval(SpinnerClock.period)
            #expect(abs(SpinnerClock.angle(at: later) - SpinnerClock.angle(at: date)) < 0.001)
        }
    }

    @Test("A date before the epoch still lands in range, and turns the same way")
    func beforeEpoch() {
        for offset in stride(from: -3.0, to: 0, by: 0.07) {
            let angle = SpinnerClock.angle(at: SpinnerClock.epoch.addingTimeInterval(offset))
            #expect(angle >= 0 && angle < 360)
        }
        let quarterBefore = SpinnerClock.epoch.addingTimeInterval(-0.25 * SpinnerClock.period)
        #expect(abs(SpinnerClock.angle(at: quarterBefore) - 270) < 0.001)
    }

    @Test("The dots and the cog read the same clock, each at its own period (#2044)")
    func dotsAndCog() {
        for period in [SpinnerClock.dotsPeriod, SpinnerClock.cogPeriod] {
            // A whole number of cycles after the epoch, so the cycle starts there.
            let start = SpinnerClock.epoch.addingTimeInterval(400 * period)
            for n in 0..<8 {
                let date = start.addingTimeInterval(Double(n) / 8 * period)
                let fraction = SpinnerClock.fraction(at: date, period: period)
                #expect(abs(fraction - Double(n) / 8) < 0.001)
                let later = SpinnerClock.fraction(at: date.addingTimeInterval(period), period: period)
                #expect(abs(later - fraction) < 0.001)
            }
            let before = SpinnerClock.fraction(at: SpinnerClock.epoch.addingTimeInterval(-0.25 * period),
                                               period: period)
            #expect(abs(before - 0.75) < 0.001)
        }
    }
}
