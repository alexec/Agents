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

    @Test("Every working ring reads the same clock, at the ring's period (#2332)")
    func ringClock() {
        let period = SpinnerClock.ringPeriod
        // A whole number of cycles after the epoch, so the cycle starts there.
        let start = SpinnerClock.epoch.addingTimeInterval(400 * period)
        for n in 0..<8 {
            let date = start.addingTimeInterval(Double(n) / 8 * period)
            // On the circle: 0.9999… and 0 are the same place in the cycle.
            let apart = { (a: Double, b: Double) in min(abs(a - b), 1 - abs(a - b)) }
            let fraction = SpinnerClock.fraction(at: date, period: period)
            #expect(apart(fraction, Double(n) / 8) < 0.001)
            let later = SpinnerClock.fraction(at: date.addingTimeInterval(period), period: period)
            #expect(apart(later, fraction) < 0.001)
        }
        let before = SpinnerClock.fraction(at: SpinnerClock.epoch.addingTimeInterval(-0.25 * period),
                                           period: period)
        #expect(abs(before - 0.75) < 0.001)
        // The cycle holds whole turns and whole pivots, so it loops without a jump.
        let turns = period / SpinnerClock.ringSpinPeriod
        #expect(abs(turns - turns.rounded()) < 1e-9)
        let pivots = period / SpinnerClock.ringPivotPeriod
        #expect(abs(pivots - pivots.rounded()) < 1e-9)
    }

    @Test("The waiting beacon breathes: dim at the start, full halfway, back round, in step (#2456)")
    func breath() {
        let dim = SpinnerClock.breathDimOpacity
        #expect(abs(SpinnerClock.breathOpacity(at: 0) - dim) < 1e-9)
        #expect(abs(SpinnerClock.breathOpacity(at: SpinnerClock.breathPeriod / 2) - 1) < 1e-9)
        #expect(abs(SpinnerClock.breathOpacity(at: SpinnerClock.breathPeriod) - dim) < 1e-9)
        // A quarter in it is halfway up, and the slope is gentle at both ends: no corners.
        #expect(abs(SpinnerClock.breathOpacity(at: 1) - (dim + (1 - dim) / 2)) < 1e-9)
        #expect(SpinnerClock.breathOpacity(at: 0.1) - dim < 0.01)
        for n in 0..<40 {
            let time = Double(n) / 40 * SpinnerClock.breathPeriod
            let opacity = SpinnerClock.breathOpacity(at: time)
            #expect(opacity >= dim - 1e-9 && opacity <= 1 + 1e-9)
            #expect(abs(SpinnerClock.breathOpacity(at: time + SpinnerClock.breathPeriod) - opacity) < 1e-9)
        }
        // A longer breath from the key keeps the same shape, stretched.
        #expect(abs(SpinnerClock.breathOpacity(at: 4, period: 8) - 1) < 1e-9)
        // Every beacon reads the one clock, so two that never met agree.
        let date = SpinnerClock.epoch.addingTimeInterval(1234.5)
        let first = SpinnerClock.fraction(at: date, period: SpinnerClock.breathPeriod)
        let second = SpinnerClock.fraction(at: Date(timeIntervalSince1970: date.timeIntervalSince1970),
                                           period: SpinnerClock.breathPeriod)
        #expect(first == second)
        // As dim as the ring's back.
        #expect(dim == SpinnerClock.ringRestingOpacity)
    }

    @Test("The breath's period comes from the defaults key, between 1 and 30 s, else 4 (#2456)")
    func breathPeriodKey() {
        #expect(SpinnerClock.breathPeriod(from: nil) == 4)
        #expect(SpinnerClock.breathPeriod(from: .nan) == 4)
        #expect(SpinnerClock.breathPeriod(from: .infinity) == 4)
        #expect(SpinnerClock.breathPeriod(from: 6) == 6)
        #expect(SpinnerClock.breathPeriod(from: 0.2) == 1)
        #expect(SpinnerClock.breathPeriod(from: 90) == 30)
        #expect(SpinnerClock.breathPeriodKey == "waitingMarkPeriod")
    }

    @Test("At rest the ring is today's three dots: a line, 0.34 apart, the middle one bright")
    func ringAtRest() throws {
        for tilt in [0.0, SpinnerClock.ringTilt] {
            let dots = SpinnerClock.ringDots(at: 0, tilt: tilt)
            try #require(dots.count == 3)
            #expect(abs(dots[0].x + 0.34) < 1e-9)
            #expect(abs(dots[1].x) < 1e-9)
            #expect(abs(dots[2].x - 0.34) < 1e-9)
            if tilt == 0 {
                for dot in dots { #expect(abs(dot.y) < 1e-9) }
                #expect(abs(dots[1].opacity - 1) < 1e-9)
            }
        }
    }

    @Test("A dot is bright at the front, 0.3 at the back, and on the line while flat")
    func ringDot() {
        let front = SpinnerClock.ringDot(spin: .pi / 2, tilt: 0)
        #expect(abs(front.x) < 1e-9 && abs(front.y) < 1e-9 && abs(front.opacity - 1) < 1e-9)
        let back = SpinnerClock.ringDot(spin: -.pi / 2, tilt: 0)
        #expect(abs(back.opacity - 0.3) < 1e-9)
        let side = SpinnerClock.ringDot(spin: 0, tilt: 0)
        #expect(abs(side.x - SpinnerClock.ringRadius) < 1e-9 && abs(side.opacity - 0.65) < 1e-9)
        // Tipped 30°: the front dot rises by r·sin 30° and dims by the cosine.
        let tipped = SpinnerClock.ringDot(spin: .pi / 2, tilt: .pi / 6)
        #expect(abs(tipped.y - SpinnerClock.ringRadius / 2) < 1e-9)
        #expect(abs(tipped.opacity - (0.3 + 0.7 * (cos(.pi / 6) + 1) / 2)) < 1e-9)
        // The ellipse at full tilt fits the well: about 0.2 of the side above and below.
        #expect(SpinnerClock.ringRadius * sin(.pi / 6) < 0.2 + 1e-3)
    }

    @Test("Thinking spins on the line; a tool pivots it, and the front goes left to right")
    func ringMotion() throws {
        for step in 0..<36 {
            let time = Double(step) / 36 * SpinnerClock.ringPeriod
            for dot in SpinnerClock.ringDots(at: time, tilt: 0) { #expect(abs(dot.y) < 1e-9) }
        }
        // A quarter of a pivot in, the ring is edge on again; at half a pivot it is tipped
        // the other way, so the front dot is below the line.
        let quarter = SpinnerClock.ringDots(at: SpinnerClock.ringPivotPeriod / 4, tilt: 30)
        for dot in quarter { #expect(abs(dot.y) < 1e-9) }
        let start = SpinnerClock.ringDots(at: 0, tilt: 30)
        let half = SpinnerClock.ringDots(at: SpinnerClock.ringPivotPeriod / 2, tilt: 30)
        let soon = SpinnerClock.ringDots(at: 0.05, tilt: 0)
        try #require(start.count == 3 && half.count == 3 && soon.count == 3)
        #expect(start[1].y > 0)
        #expect(half[1].y < 0)
        // Just after the start, the front (middle) dot has moved right.
        #expect(soon[1].x > 0)
        // After a whole cycle every dot is back where it began.
        let again = SpinnerClock.ringDots(at: SpinnerClock.ringPeriod, tilt: 30)
        for (a, b) in zip(start, again) {
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9 && abs(a.opacity - b.opacity) < 1e-9)
        }
    }
}
