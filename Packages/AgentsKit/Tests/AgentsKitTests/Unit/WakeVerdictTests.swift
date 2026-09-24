import Foundation
import Testing
@testable import AgentsKit

/// The whole of this feature's logic, with no daemon, no agent and no hardware.
///
/// Worth having in this shape because the function is total over two inputs and the
/// expensive mistakes are all boundary mistakes: an inclusive floor read as exclusive,
/// a desktop treated as a flat battery, mains forgotten when the charge is low.
@Suite("Whether the Mac should be held awake")
struct WakeVerdictTests {

    // MARK: Nothing computing

    @Test("Nothing in flight holds nothing, whatever the power is doing")
    func idleWhateverThePower() {
        for power in [PowerReading(batteryPercent: 100, isOnMains: true),
                      PowerReading(batteryPercent: 5, isOnMains: false),
                      PowerReading(batteryPercent: nil, isOnMains: true)] {
            #expect(Wake.verdict(workInFlight: false, power: power) == .idle)
        }
    }

    // MARK: Mains

    @Test("On mains the charge is not our business, even at 5%")
    func mainsIgnoresCharge() {
        let power = PowerReading(batteryPercent: 5, isOnMains: true)
        #expect(Wake.verdict(workInFlight: true, power: power) == .hold)
    }

    @Test("A Mac with no battery is treated as mains")
    func desktopHolds() {
        // The distinction the `Int?` exists for: a desktop is not a flat battery. If
        // `batteryPercent` were a non-optional 0, this case would answer
        // `batteryTooLow` and a Mac Studio would never hold the assertion at all.
        let power = PowerReading(batteryPercent: nil, isOnMains: false)
        #expect(Wake.verdict(workInFlight: true, power: power) == .hold)
    }

    // MARK: The floor, which is inclusive

    @Test("Well above the floor holds")
    func comfortablyAboveFloorHolds() {
        let power = PowerReading(batteryPercent: 77, isOnMains: false)
        #expect(Wake.verdict(workInFlight: true, power: power) == .hold)
    }

    @Test("One percent above the floor still holds")
    func justAboveFloorHolds() {
        let power = PowerReading(batteryPercent: Wake.batteryFloorPercent + 1, isOnMains: false)
        #expect(Wake.verdict(workInFlight: true, power: power) == .hold)
    }

    @Test("At the floor is too low — FR-010 says 'reaches or falls below'")
    func atFloorIsTooLow() {
        // The line this suite exists for. `>` and `>=` both read plausibly in the
        // source and only one of them matches the requirement.
        let power = PowerReading(batteryPercent: Wake.batteryFloorPercent, isOnMains: false)
        #expect(Wake.verdict(workInFlight: true, power: power)
                == .batteryTooLow(percent: Wake.batteryFloorPercent))
    }

    @Test("Below the floor is too low, and carries the reading for the words")
    func belowFloorIsTooLow() {
        let power = PowerReading(batteryPercent: 19, isOnMains: false)
        #expect(Wake.verdict(workInFlight: true, power: power) == .batteryTooLow(percent: 19))
    }

    @Test("A flat battery is too low, not idle")
    func flatIsTooLowNotIdle() {
        // `batteryTooLow` rather than `idle` even at zero, because FR-016 needs to say
        // something different from silence while work is still in flight.
        let power = PowerReading(batteryPercent: 0, isOnMains: false)
        #expect(Wake.verdict(workInFlight: true, power: power) == .batteryTooLow(percent: 0))
    }

    // MARK: What the verdict means to the assertion

    @Test("Only `hold` holds")
    func onlyHoldHolds() {
        #expect(WakeVerdict.hold.isHolding)
        #expect(!WakeVerdict.idle.isHolding)
        #expect(!WakeVerdict.batteryTooLow(percent: 3).isHolding)
    }

    // MARK: The reading itself

    @Test("A percentage is clamped rather than trusted")
    func percentageIsClamped() {
        #expect(PowerReading(batteryPercent: 140, isOnMains: false).batteryPercent == 100)
        #expect(PowerReading(batteryPercent: -3, isOnMains: false).batteryPercent == 0)
        #expect(PowerReading(batteryPercent: nil, isOnMains: false).batteryPercent == nil)
    }

    @Test("A machine that will not say is treated as mains, so the failure is the visible one")
    func unknownHolds() {
        // Holding wrongly leaves a Mac awake, which `pmset` will name us for.
        // Releasing wrongly loses a turn, silently. The default goes the visible way.
        #expect(Wake.verdict(workInFlight: true, power: .unknown) == .hold)
        #expect(Wake.verdict(workInFlight: false, power: .unknown) == .idle)
    }

    // MARK: The real reader

    @Test("The real power source answers something coherent on this machine")
    func iokitReadsSomething() {
        // Deliberately weak: this runs on whatever machine the suite runs on, and the
        // only universal truth is that a reading is internally consistent. The point
        // is to catch an IOKit call that throws, returns nothing, or hands back a
        // percentage outside 0...100 — not to assert this Mac's charge.
        let reading = IOKitPowerSource().read()
        if let percent = reading.batteryPercent {
            #expect((0...100).contains(percent))
        }
    }
}
