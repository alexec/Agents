import Foundation
import Testing
@testable import AgentsKitCore

/// When a volume is low, and when it is back, without flapping (#195).
@Suite("Disk space levels")
struct DiskSpaceTests {
    private let gb = DiskSpace.gigabyte

    /// A 1 TB disk with `free` GB free: 5% of it is 50 GB, more than the 20 GB default.
    private func reading(_ free: Double, total: Int64 = 1000) -> DiskReading {
        DiskReading(volume: "Macintosh HD", mount: "/", freeBytes: Int64(free * Double(gb)), totalBytes: total * gb)
    }

    @Test func theLowLineIsTwentyGBOrFivePercentWhicheverIsMore() {
        #expect(DiskThresholds().lowLine(total: 1000 * gb) == 50 * gb)
        #expect(DiskThresholds().lowLine(total: 200 * gb) == 20 * gb)
        #expect(DiskThresholds().criticalLine == 2 * gb)
        #expect(DiskThresholds(lowGB: 100).lowLine(total: 1000 * gb) == 100 * gb)
    }

    @Test func aFirstLookSaysOnlyWhatIsWrong() {
        #expect(DiskSpace.next(from: nil, reading(400), DiskThresholds()) == (.ok, nil))
        let low = DiskSpace.next(from: nil, reading(30), DiskThresholds())
        #expect(low.level == .low)
        #expect(low.crossing == .low(.low, threshold: 50 * gb))
        let critical = DiskSpace.next(from: nil, reading(1), DiskThresholds())
        #expect(critical.crossing == .low(.critical, threshold: 2 * gb))
    }

    @Test func eachCrossingIsSaidOnceAndNotAgainWhileItStays() {
        var level: DiskLevel? = .ok
        var said: [DiskCrossing] = []
        for free in [400, 60, 49, 45, 40, 30, 1.5, 1.2, 0.9, 1.5] as [Double] {
            let next = DiskSpace.next(from: level, reading(free), DiskThresholds())
            level = next.level
            if let crossing = next.crossing { said.append(crossing) }
        }
        #expect(said == [.low(.low, threshold: 50 * gb), .low(.critical, threshold: 2 * gb)])
        #expect(level == .critical)
    }

    /// Climbing back must pass the line by a margin — a tenth of it, at least 1 GB — so a
    /// volume hovering at the line does not say low, ok, low, ok.
    @Test func climbingBackNeedsTheMargin() {
        let thresholds = DiskThresholds()
        // Low is below 50 GB; ok again only from 55 GB.
        #expect(DiskSpace.next(from: .low, reading(51), thresholds) == (.low, nil))
        #expect(DiskSpace.next(from: .low, reading(54.9), thresholds) == (.low, nil))
        #expect(DiskSpace.next(from: .low, reading(55), thresholds) == (.ok, .ok(threshold: 50 * gb)))
        // Hovering at the line: one low, then quiet.
        var level: DiskLevel? = .ok
        var said = 0
        for free in [50.5, 49.5, 50.5, 49.5, 50.5, 49.8] as [Double] {
            let next = DiskSpace.next(from: level, reading(free), thresholds)
            level = next.level
            if next.crossing != nil { said += 1 }
        }
        #expect(said == 1)
        #expect(level == .low)
    }

    @Test func fromCriticalBackToLowIsNotNewsButCriticalAgainIs() {
        let thresholds = DiskThresholds()
        // Critical is below 2 GB; left only from 3 GB.
        #expect(DiskSpace.next(from: .critical, reading(2.5), thresholds) == (.critical, nil))
        #expect(DiskSpace.next(from: .critical, reading(10), thresholds) == (.low, nil))
        #expect(DiskSpace.next(from: .low, reading(1), thresholds).crossing == .low(.critical, threshold: 2 * gb))
        // Straight from critical to plenty is ok.
        #expect(DiskSpace.next(from: .critical, reading(400), thresholds) == (.ok, .ok(threshold: 50 * gb)))
    }

    @Test func theStrictestOfSeveralProjectsWins() {
        let lines = DiskThresholds.strictest([DiskThresholds(lowGB: 10), DiskThresholds(lowGB: 50, criticalGB: 1)])
        #expect(lines.effectiveLowGB == 50)
        #expect(lines.effectiveCriticalGB == 2, "one at the default is the default's 2 GB")
        #expect(DiskThresholds.strictest([]) == DiskThresholds())
    }

    @Test func aSettingIsKeptOnlyWhenItDiffersAndMakesSense() {
        #expect(DiskThresholds(lowGB: 20, criticalGB: 2).orNilIfDefault == nil)
        #expect(DiskThresholds(lowGB: 50).orNilIfDefault == DiskThresholds(lowGB: 50))
        #expect(DiskThresholds(lowGB: 5, criticalGB: 10).problem != nil)
        #expect(DiskThresholds(lowGB: 0).problem != nil)
        #expect(DiskThresholds(lowGB: 50).problem == nil)
    }

    @Test func theStripSaysHowMuchIsFreeAndTheLargestWorktrees() {
        let alarm = DiskAlarm(reading: reading(12.34), level: .low, threshold: 50 * gb,
                              worktrees: [DiskWorktree(name: "fix-1", bytes: 30 * gb, partial: true),
                                          DiskWorktree(name: "fix-2", bytes: 850_000_000)])
        #expect(alarm.line == "Macintosh HD is running low: 12.3 GB free (1%). "
                + "Largest worktrees: fix-1 over 30.0 GB, fix-2 850 MB.")
        let almostFull = DiskReading(volume: "Macintosh HD", mount: "/", freeBytes: 143_000_000, totalBytes: 1000 * gb)
        let critical = DiskAlarm(reading: almostFull, level: .critical, threshold: 2 * gb)
        #expect(critical.line == "Macintosh HD is almost full: 143 MB free. Agents’ commands will start failing.")
    }
}
