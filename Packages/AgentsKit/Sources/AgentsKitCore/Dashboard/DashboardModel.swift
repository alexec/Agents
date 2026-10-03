import Foundation

/// What a Dashboard means, said once for the Mac, the Remote and the host (074). The web
/// page says the same in `Web/src/model/dashboard.ts`.
public enum DashboardModel {
    /// Past its own stale-after time, or never set on this host (FR-024, a clone).
    public static func isStale(_ tile: TileView, now: Date) -> Bool {
        guard let file = tile.tile, let setAt = tile.setAt else { return true }
        return now.timeIntervalSince(setAt) > file.staleAfter
    }

    /// The level a status tile shows: a stale one says nothing, so a green light nobody
    /// has confirmed stops saying all is well (FR-024).
    public static func shownLevel(_ tile: TileView, now: Date) -> TileLevel? {
        guard let status = tile.tile?.status else { return nil }
        return isStale(tile, now: now) ? .unknown : status.level
    }

    /// The tile's foot after its keeper: "just now", "12 min ago", "3 h ago", or for a
    /// stale tile "2 days old"; "age unknown" when this host never saw it set.
    public static func ageWords(_ tile: TileView, now: Date) -> String {
        guard let setAt = tile.setAt else { return "age unknown" }
        let seconds = max(0, now.timeIntervalSince(setAt))
        let stale = isStale(tile, now: now)
        let minutes = Int(seconds / 60), hours = Int(seconds / 3600), days = Int(seconds / 86_400)
        if stale {
            if days >= 1 { return days == 1 ? "1 day old" : "\(days) days old" }
            return hours <= 1 ? "1 hour old" : "\(hours) hours old"
        }
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if hours < 24 { return "\(hours) h ago" }
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// What its foot says about the keeper beyond its name (FR-025).
    public static func keeperNote(_ keeper: KeeperView) -> String? {
        switch keeper.state {
        case .archived: keeper.kind == .workflow ? "its workflow is archived" : "its agent is archived"
        case .retired: "its agent is retired"
        case .active, .unknown: nil
        }
    }

    /// The change since a day ago: against the last point at least 24 hours old, or the
    /// first point when there is none that old (spec, Assumptions). Nil with one point.
    public static func change(_ tile: TileView, now: Date) -> Double? {
        guard let value = tile.tile?.number?.value, tile.points.count > 1 else { return nil }
        let dayAgo = (tile.setAt ?? now).addingTimeInterval(-86_400)
        let base = tile.points.last(where: { $0.at <= dayAgo }) ?? tile.points.first
        guard let base else { return nil }
        return value - base.value
    }

    /// Whether a change is good news, by the tile's `good`; nil when it says neither.
    public static func isGood(change: Double, good: TileGood?) -> Bool? {
        guard let good, change != 0 else { return nil }
        return (change > 0) == (good == .up)
    }

    /// A number as a tile shows it: whole numbers with thousands separators, others to
    /// at most two places.
    public static func numberWords(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "▲2", "▼5", or nil for none.
    public static func changeWords(_ change: Double?) -> String? {
        guard let change, change != 0 else { return nil }
        return (change > 0 ? "▲" : "▼") + numberWords(abs(change))
    }

    /// The tiles grouped by section, sections in the order their first tile was made and
    /// tiles in the order they were made (spec, Assumptions). Hidden tiles left out
    /// unless asked for.
    public static func sections(_ snapshot: DashboardSnapshot, includeHidden: Bool = false)
        -> [(title: String?, tiles: [TileView])] {
        var order: [String?] = []
        var grouped: [String?: [TileView]] = [:]
        for tile in ordered(snapshot.tiles) where includeHidden || tile.tile?.isHidden != true {
            let section = tile.tile?.section
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(tile)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    /// Made order, then id; a tile only a file knows of goes after those the host made.
    public static func ordered(_ tiles: [TileView]) -> [TileView] {
        tiles.sorted { a, b in
            switch (a.made, b.made) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.id < b.id
            }
        }
    }

    /// The row's summary (FR-031, FR-032), ignoring stale and hidden tiles (FR-026).
    public static func summary(_ snapshot: DashboardSnapshot) -> DashboardSummary {
        let shown = ordered(snapshot.tiles).filter { $0.tile?.isHidden != true }
        let live = shown.filter { !isStale($0, now: snapshot.now) }
        let bad = live.filter { $0.tile?.status?.level == .bad }.count
        let warn = live.filter { $0.tile?.status?.level == .warn }.count
        var parts: [String] = []
        if bad > 0 { parts.append("\(bad) needs a look") }
        else if warn > 0 { parts.append("\(warn) to watch") }
        if let first = live.first(where: { $0.tile?.number != nil }), let file = first.tile, let number = file.number {
            parts.append("\(file.title) \(numberWords(number.value))\(number.unit.map { $0.isEmpty ? "" : " \($0)" } ?? "")")
        }
        return DashboardSummary(folder: snapshot.folder, tiles: shown.count, bad: bad,
                                line: parts.joined(separator: " · "))
    }
}
