import Foundation

/// The whole stores Agents Host sets aside in the control plane's home (`store-before-*`), on
/// a store switch or a move back, and this Mac's control plane keys set aside on a move back
/// (`control-key-before-*`). Only the newest `kept` of each stay (#3671): a move back needs
/// only the last one, and each folder holds an audit, sealed secrets and server backups.
public enum StoresAside {
    public static let kept = 2
    public static let folderPrefix = "store-before-"
    public static let keyPrefix = "control-key-before-"

    /// When `name` was set aside, from its name: `store-before-<seconds>` (a switch),
    /// `store-before-<yyyy-mm-dd>-<seconds % 100000>` (a move back) or
    /// `control-key-before-<seconds>`. Nil for any other name.
    public static func time(of name: String) -> Date? {
        let rest: Substring
        if name.hasPrefix(folderPrefix) {
            rest = name.dropFirst(folderPrefix.count)
        } else if name.hasPrefix(keyPrefix) {
            rest = name.dropFirst(keyPrefix.count)
        } else {
            return nil
        }
        if let seconds = Int(rest) { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        // A day (UTC, as `.iso8601` writes it) and the seconds modulo 100,000: a day is
        // shorter than 100,000 seconds, so at most one time in that day fits.
        guard rest.count > 11, let low = Int(rest.dropFirst(11)), rest[rest.index(rest.startIndex, offsetBy: 10)] == "-",
              let day = try? Date(String(rest.prefix(10)), strategy: .iso8601.year().month().day()) else { return nil }
        let start = Int(day.timeIntervalSince1970)
        let seconds = start + ((low - start) % 100_000 + 100_000) % 100_000
        return Date(timeIntervalSince1970: TimeInterval(seconds < start + 86_400 ? seconds : start))
    }

    /// The names past the newest `keep`, oldest first. Names with no time are left alone.
    public static func beyond(_ names: [String], keep: Int = kept) -> [String] {
        let dated = names.compactMap { name in time(of: name).map { (name, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }
        return dated.dropFirst(keep).reversed().map(\.0)
    }

    /// Deletes the `store-before-*` folders in `home` past the newest `keep`. Answers the
    /// names deleted; one that could not be deleted is left for the next time.
    @discardableResult
    public static func pruneFolders(in home: URL, keep: Int = kept) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return beyond(names.filter { $0.hasPrefix(folderPrefix) }, keep: keep).filter {
            (try? FileManager.default.removeItem(at: home.appendingPathComponent($0))) != nil
        }
    }
}
