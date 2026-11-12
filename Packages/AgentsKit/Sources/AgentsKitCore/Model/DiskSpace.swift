import Foundation

/// How full a volume is allowed to get before the app says so (#195): `machine.disk_low` and
/// `machine.disk_ok`, and the machine's row and page (#3628).
///
/// Each line is a percent of the volume, not a size, so one setting fits a 256 GB laptop
/// and a 4 TB server alike (Alex, 2026-11-11). Set in a folder's `.agents/folder.json`
/// beside `helperLimits`, or in Folder Settings. A nil field is its default. A volume
/// holding several folders goes by the most careful of the settings those that set one
/// chose: the highest line of each. When none sets one, the defaults.
///
///     "diskSpace" : { "lowPercent" : 10, "criticalPercent" : 1 }
public struct DiskThresholds: Codable, Hashable, Sendable {
    /// Below this percent of the volume free is `low`: where the Free disk space workflow starts.
    public var lowPercent: Int?
    /// Below this percent free is `critical`: where writes start failing.
    public var criticalPercent: Int?

    public static let defaultLowPercent = 10
    public static let defaultCriticalPercent = 1
    /// The choices Folder Settings offers.
    public static let lowChoices = [5, 10, 20, 30, 50]
    public static let criticalChoices = [1, 2, 5, 10]

    public init(lowPercent: Int? = nil, criticalPercent: Int? = nil) {
        self.lowPercent = lowPercent
        self.criticalPercent = criticalPercent
    }

    public var effectiveLowPercent: Int { lowPercent ?? Self.defaultLowPercent }
    public var effectiveCriticalPercent: Int { criticalPercent ?? Self.defaultCriticalPercent }

    /// Nil when nothing differs from the defaults, so a file says only what was chosen.
    public var orNilIfDefault: DiskThresholds? {
        var kept = self
        if kept.lowPercent == Self.defaultLowPercent { kept.lowPercent = nil }
        if kept.criticalPercent == Self.defaultCriticalPercent { kept.criticalPercent = nil }
        return kept == DiskThresholds() ? nil : kept
    }

    /// Why a setting cannot be kept, in the person's words; nil when it can.
    public var problem: String? {
        if let lowPercent, !(1...90).contains(lowPercent) { return "Low disk space must be between 1 and 90 percent." }
        if let criticalPercent, !(0...90).contains(criticalPercent) {
            return "Critical disk space must be between 0 and 90 percent."
        }
        if effectiveCriticalPercent > effectiveLowPercent {
            return "Critical disk space can't be more than low disk space."
        }
        return nil
    }

    /// The most careful of several settings: each line at its highest.
    public static func strictest(_ all: [DiskThresholds]) -> DiskThresholds {
        guard !all.isEmpty else { return DiskThresholds() }
        return DiskThresholds(lowPercent: all.map(\.effectiveLowPercent).max(),
                              criticalPercent: all.map(\.effectiveCriticalPercent).max())
    }

    /// Bytes free below which a volume of `total` bytes is low.
    public func lowLine(total: Int64) -> Int64 { total / 100 * Int64(effectiveLowPercent) }

    /// Bytes free below which a volume of `total` bytes is critical.
    public func criticalLine(total: Int64) -> Int64 { total / 100 * Int64(effectiveCriticalPercent) }
}

/// How a volume stands. Worse is greater.
public enum DiskLevel: String, Codable, Hashable, Sendable, Comparable, CaseIterable {
    case ok
    case low
    case critical

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (lhs: DiskLevel, rhs: DiskLevel) -> Bool { lhs.rank < rhs.rank }
}

/// One look at a volume.
public struct DiskReading: Codable, Hashable, Sendable {
    /// The volume's name, as the person knows it ("Macintosh HD").
    public var volume: String
    /// Where it is mounted: what tells two volumes apart.
    public var mount: String
    public var freeBytes: Int64
    public var totalBytes: Int64

    public init(volume: String, mount: String, freeBytes: Int64, totalBytes: Int64) {
        self.volume = volume
        self.mount = mount
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }

    /// Whole percent free, rounded down.
    public var freePercent: Int {
        totalBytes > 0 ? Int(Double(freeBytes) / Double(totalBytes) * 100) : 0
    }
}

/// A worktree and how much it holds, measured once at a crossing within a budget.
public struct DiskWorktree: Codable, Hashable, Sendable {
    public var name: String
    public var bytes: Int64
    /// The budget ran out before all of it was counted, so `bytes` is at least.
    public var partial: Bool

    public init(name: String, bytes: Int64, partial: Bool = false) {
        self.name = name
        self.bytes = bytes
        self.partial = partial
    }
}

/// A volume that is low or critical, as the window draws it.
public struct DiskAlarm: Codable, Hashable, Sendable, Identifiable {
    public var reading: DiskReading
    public var level: DiskLevel
    /// The line it fell below, in bytes.
    public var threshold: Int64
    /// The largest worktrees on it, largest first, when they could be measured.
    public var worktrees: [DiskWorktree]

    public var id: String { reading.mount }

    public init(reading: DiskReading, level: DiskLevel, threshold: Int64, worktrees: [DiskWorktree] = []) {
        self.reading = reading
        self.level = level
        self.threshold = threshold
        self.worktrees = worktrees
    }

    /// One line for the strip.
    public var line: String {
        let free = DiskSpace.words(reading.freeBytes)
        let what = level == .critical
            ? "\(reading.volume) is almost full: \(free) free. Agents’ commands will start failing."
            : "\(reading.volume) is running low: \(free) free (\(reading.freePercent)%)."
        guard !worktrees.isEmpty else { return what }
        return what + " Largest worktrees: " + DiskSpace.worktreeWords(worktrees.prefix(3)) + "."
    }
}

/// What `disk/state` answers and `disk/changed` carries: every volume not ok.
public struct DiskState: Codable, Hashable, Sendable {
    public var alarms: [DiskAlarm]
    public init(alarms: [DiskAlarm] = []) { self.alarms = alarms }
}

/// What a look found changed.
public enum DiskCrossing: Hashable, Sendable {
    /// Fell to `level`, below `threshold` bytes.
    case low(DiskLevel, threshold: Int64)
    /// Climbed back above `threshold` plus the margin.
    case ok(threshold: Int64)
}

public enum DiskSpace {
    public static let gigabyte: Int64 = 1_000_000_000
    /// How often the daemon looks.
    public static let interval: Duration = .seconds(60)

    /// How far above a line free space must climb before the level it marks is left,
    /// so a volume hovering at the line doesn't flap: a tenth of the line, at least 1 GB.
    public static func margin(above line: Int64) -> Int64 {
        max(line / 10, gigabyte)
    }

    /// Where a volume stands after `reading`, having stood at `before` (nil: never looked
    /// at), and what to say about it. Worse is said at once; better only once free space
    /// has climbed past the line plus the margin, and only `ok` is said: from critical to
    /// low is not news.
    public static func next(from before: DiskLevel?, _ reading: DiskReading,
                            _ thresholds: DiskThresholds) -> (level: DiskLevel, crossing: DiskCrossing?) {
        let free = reading.freeBytes
        let low = thresholds.lowLine(total: reading.totalBytes)
        let critical = thresholds.criticalLine(total: reading.totalBytes)
        let raw: DiskLevel = free < critical ? .critical : free < low ? .low : .ok
        let was = before ?? .ok
        if raw > was {
            return (raw, .low(raw, threshold: raw == .critical ? critical : low))
        }
        // Better: only past the margin of each line left behind.
        var level = was
        if level == .critical, free >= critical + margin(above: critical) { level = .low }
        if level == .low, free >= low + margin(above: low) { level = .ok }
        level = max(level, raw)
        if level == .ok, was != .ok { return (.ok, .ok(threshold: low)) }
        return (level, nil)
    }

    /// "12.3 GB", "850 MB".
    public static func words(_ bytes: Int64) -> String {
        if bytes >= gigabyte {
            return String(format: "%.1f GB", Double(bytes) / Double(gigabyte))
        }
        return "\(max(0, bytes) / 1_000_000) MB"
    }

    /// A volume on a machine's page (#3626): "120.3 GB free of 500.0 GB (24%)".
    public static func freeWords(_ reading: DiskReading) -> String {
        "\(words(reading.freeBytes)) free of \(words(reading.totalBytes)) (\(reading.freePercent)%)"
    }

    /// A level as a machine's page says it, beside the volume (#3626).
    public static func levelWords(_ level: DiskLevel) -> String {
        switch level {
        case .ok: "OK"
        case .low: "Low"
        case .critical: "Almost full"
        }
    }

    /// The disk a machine's page shows open (#3743): the worst; of equal levels, the one
    /// most of `folders` are on; then the one with least free. The others fold away.
    public static func headline(_ disks: [DiskAlarm], folders: [String]) -> DiskAlarm? {
        let on = Dictionary(grouping: folders.compactMap { mount(of: $0, in: disks) }, by: { $0 }).mapValues(\.count)
        return disks.max { a, b in
            if a.level != b.level { return a.level < b.level }
            let (x, y) = (on[a.reading.mount] ?? 0, on[b.reading.mount] ?? 0)
            if x != y { return x < y }
            return a.reading.freeBytes > b.reading.freeBytes
        }
    }

    /// The mount a path is on: the longest of `disks`' mounts that holds it.
    static func mount(of path: String, in disks: [DiskAlarm]) -> String? {
        disks.map(\.reading.mount)
            .filter { $0 == "/" || path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    /// A disk in a machine's summary (#3743): "Disk 48.0 GB free", and its level when it is not OK.
    public static func summaryWords(_ disk: DiskAlarm) -> String {
        let free = "Disk \(words(disk.reading.freeBytes)) free"
        return disk.level == .ok ? free : "\(free) · \(levelWords(disk.level))"
    }

    /// A low disk in the grey line under a machine's row (#3928): "Disk low: 24.7 GB free",
    /// "Disk almost full: 1.8 GB free".
    public static func needWords(_ disk: DiskAlarm) -> String {
        "Disk \(levelWords(disk.level).lowercased()): \(words(disk.reading.freeBytes)) free"
    }

    /// "a 12.3 GB, b over 8.0 GB".
    public static func worktreeWords(_ worktrees: some Sequence<DiskWorktree>) -> String {
        worktrees.map { "\($0.name) \($0.partial ? "over " : "")\(words($0.bytes))" }.joined(separator: ", ")
    }
}
