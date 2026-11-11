import Foundation
import Testing
@testable import AgentsKitCore

/// When a volume is low, and when it is back, without flapping (#195).
@Suite("Disk space levels")
struct DiskSpaceTests {
    private let gb = DiskSpace.gigabyte

    /// A 1 TB disk with `free` GB free: 20% of it, the low line, is 200 GB; 1%, critical, is 10 GB.
    private func reading(_ free: Double, total: Int64 = 1000) -> DiskReading {
        DiskReading(volume: "Macintosh HD", mount: "/", freeBytes: Int64(free * Double(gb)), totalBytes: total * gb)
    }

    /// A percent of the disk, never a size: the same setting is 200 GB on a 1 TB disk and 40 GB on a 200 GB one.
    @Test func theLinesAreAPercentOfTheDisk() {
        #expect(DiskThresholds().lowLine(total: 1000 * gb) == 200 * gb)
        #expect(DiskThresholds().lowLine(total: 200 * gb) == 40 * gb)
        #expect(DiskThresholds().criticalLine(total: 1000 * gb) == 10 * gb)
        #expect(DiskThresholds().criticalLine(total: 200 * gb) == 2 * gb)
        #expect(DiskThresholds(lowPercent: 10).lowLine(total: 1000 * gb) == 100 * gb)
    }

    @Test func aFirstLookSaysOnlyWhatIsWrong() {
        #expect(DiskSpace.next(from: nil, reading(400), DiskThresholds()) == (.ok, nil))
        let low = DiskSpace.next(from: nil, reading(150), DiskThresholds())
        #expect(low.level == .low)
        #expect(low.crossing == .low(.low, threshold: 200 * gb))
        let critical = DiskSpace.next(from: nil, reading(5), DiskThresholds())
        #expect(critical.crossing == .low(.critical, threshold: 10 * gb))
    }

    @Test func eachCrossingIsSaidOnceAndNotAgainWhileItStays() {
        var level: DiskLevel? = .ok
        var said: [DiskCrossing] = []
        for free in [400, 210, 199, 180, 150, 100, 9, 8, 5, 9] as [Double] {
            let next = DiskSpace.next(from: level, reading(free), DiskThresholds())
            level = next.level
            if let crossing = next.crossing { said.append(crossing) }
        }
        #expect(said == [.low(.low, threshold: 200 * gb), .low(.critical, threshold: 10 * gb)])
        #expect(level == .critical)
    }

    /// Climbing back must pass the line by a margin — a tenth of it, at least 1 GB — so a
    /// volume hovering at the line does not say low, ok, low, ok.
    @Test func climbingBackNeedsTheMargin() {
        let thresholds = DiskThresholds()
        // Low is below 200 GB; ok again only from 220 GB.
        #expect(DiskSpace.next(from: .low, reading(201), thresholds) == (.low, nil))
        #expect(DiskSpace.next(from: .low, reading(219.9), thresholds) == (.low, nil))
        #expect(DiskSpace.next(from: .low, reading(220), thresholds) == (.ok, .ok(threshold: 200 * gb)))
        // Hovering at the line: one low, then quiet.
        var level: DiskLevel? = .ok
        var said = 0
        for free in [200.5, 199.5, 200.5, 199.5, 200.5, 199.8] as [Double] {
            let next = DiskSpace.next(from: level, reading(free), thresholds)
            level = next.level
            if next.crossing != nil { said += 1 }
        }
        #expect(said == 1)
        #expect(level == .low)
    }

    @Test func fromCriticalBackToLowIsNotNewsButCriticalAgainIs() {
        let thresholds = DiskThresholds()
        // Critical is below 10 GB; left only from 11 GB.
        #expect(DiskSpace.next(from: .critical, reading(10.5), thresholds) == (.critical, nil))
        #expect(DiskSpace.next(from: .critical, reading(50), thresholds) == (.low, nil))
        #expect(DiskSpace.next(from: .low, reading(5), thresholds).crossing == .low(.critical, threshold: 10 * gb))
        // Straight from critical to plenty is ok.
        #expect(DiskSpace.next(from: .critical, reading(400), thresholds) == (.ok, .ok(threshold: 200 * gb)))
    }

    @Test func theStrictestOfSeveralFoldersWins() {
        let lines = DiskThresholds.strictest([DiskThresholds(lowPercent: 10, criticalPercent: 2),
                                               DiskThresholds(lowPercent: 50)])
        #expect(lines.effectiveLowPercent == 50)
        #expect(lines.effectiveCriticalPercent == 2, "one at the default is the default's 1%, the other's 2% wins")
        #expect(DiskThresholds.strictest([]) == DiskThresholds())
    }

    @Test func aSettingIsKeptOnlyWhenItDiffersAndMakesSense() {
        #expect(DiskThresholds(lowPercent: 20, criticalPercent: 1).orNilIfDefault == nil)
        #expect(DiskThresholds(lowPercent: 50).orNilIfDefault == DiskThresholds(lowPercent: 50))
        #expect(DiskThresholds(lowPercent: 5, criticalPercent: 10).problem != nil)
        #expect(DiskThresholds(lowPercent: 0).problem != nil)
        #expect(DiskThresholds(lowPercent: 95).problem != nil)
        #expect(DiskThresholds(lowPercent: 50).problem == nil)
    }

    @Test func theStripSaysHowMuchIsFreeAndTheLargestWorktrees() {
        let alarm = DiskAlarm(reading: reading(12.34), level: .low, threshold: 200 * gb,
                              worktrees: [DiskWorktree(name: "fix-1", bytes: 30 * gb, partial: true),
                                          DiskWorktree(name: "fix-2", bytes: 850_000_000)])
        #expect(alarm.line == "Macintosh HD is running low: 12.3 GB free (1%). "
                + "Largest worktrees: fix-1 over 30.0 GB, fix-2 850 MB.")
        let almostFull = DiskReading(volume: "Macintosh HD", mount: "/", freeBytes: 143_000_000, totalBytes: 1000 * gb)
        let critical = DiskAlarm(reading: almostFull, level: .critical, threshold: 10 * gb)
        #expect(critical.line == "Macintosh HD is almost full: 143 MB free. Agents’ commands will start failing.")
    }

    /// A machine's page (#3626) says every volume's free of total, and its level.
    @Test func aMachinesPageSaysFreeOfTotal() {
        #expect(DiskSpace.freeWords(reading(240)) == "240.0 GB free of 1000.0 GB (24%)")
        #expect(DiskSpace.levelWords(.ok) == "OK")
        #expect(DiskSpace.levelWords(.critical) == "Almost full")
    }

    /// Its summary (#3743) names one disk: the worst, then the folders' own, then the fullest.
    @Test func aMachinesSummaryNamesOneDisk() {
        func disk(_ mount: String, _ freeGB: Int64, _ level: DiskLevel = .ok) -> DiskAlarm {
            DiskAlarm(reading: DiskReading(volume: mount, mount: mount, freeBytes: freeGB * DiskSpace.gigabyte,
                                           totalBytes: 1000 * DiskSpace.gigabyte), level: level, threshold: 0)
        }
        let root = disk("/", 400), data = disk("/Volumes/Data", 100), low = disk("/Volumes/Old", 900, .low)
        #expect(DiskSpace.headline([root, data, low], folders: ["/Users/a/x"])?.id == "/Volumes/Old")
        #expect(DiskSpace.headline([root, data], folders: ["/Users/a/x", "/Volumes/Data2/y"])?.id == "/")
        #expect(DiskSpace.headline([root, data], folders: ["/Volumes/Data/y"])?.id == "/Volumes/Data")
        #expect(DiskSpace.headline([root, data], folders: [])?.id == "/Volumes/Data", "no folders: the one with least free")
        #expect(DiskSpace.headline([], folders: []) == nil)
        #expect(DiskSpace.summaryWords(root) == "Disk 400.0 GB free")
        #expect(DiskSpace.summaryWords(low) == "Disk 900.0 GB free · Low")
    }
}
