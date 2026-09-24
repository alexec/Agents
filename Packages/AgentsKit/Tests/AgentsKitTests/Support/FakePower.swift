import Foundation
@testable import AgentsKit

/// A power reading a test names, and can change between calls.
///
/// Settable mid-test on purpose: the requirement that matters most here is what happens
/// when the charge crosses the floor **while a turn is still running** (FR-010, US3-3),
/// and the alternative way to test that is to discharge a laptop.
final class FakePowerSource: PowerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: PowerReading

    init(_ reading: PowerReading = .init(batteryPercent: nil, isOnMains: true)) {
        self.reading = reading
    }

    /// On mains, charge irrelevant. The ordinary case for a test that is not about
    /// power at all.
    static var mains: FakePowerSource { FakePowerSource(.init(batteryPercent: 80, isOnMains: true)) }

    func read() -> PowerReading {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    func set(_ reading: PowerReading) {
        lock.lock(); defer { lock.unlock() }
        self.reading = reading
    }

    func onBattery(_ percent: Int) {
        set(PowerReading(batteryPercent: percent, isOnMains: false))
    }

    func onMains(_ percent: Int? = 80) {
        set(PowerReading(batteryPercent: percent, isOnMains: true))
    }
}

/// Every hold and release, in the order they happened.
///
/// Counts rather than a boolean, because the assertions worth making are about
/// **how many times** — one hold across three overlapping agents (FR-006), and no
/// second hold when a streamed token re-enters `changed(_:)`.
final class RecordingWakefulness: Wakefulness, @unchecked Sendable {
    enum Event: Equatable {
        case held(String)
        case released
    }

    private let lock = NSLock()
    private var events: [Event] = []

    var log: [Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    var holds: Int { log.filter { if case .held = $0 { return true } else { return false } }.count }
    var releases: Int { log.filter { $0 == .released }.count }

    /// Whether a hold is outstanding: the last thing that happened was a hold.
    var isHolding: Bool {
        guard let last = log.last else { return false }
        if case .held = last { return true }
        return false
    }

    /// The reason given to the most recent hold, which is what `pmset` would show.
    var lastReason: String? {
        for event in log.reversed() {
            if case .held(let reason) = event { return reason }
        }
        return nil
    }

    func hold(reason: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(.held(reason))
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        events.append(.released)
    }
}
