import Foundation

/// Which features are used (#2165): what each host counted at its method dispatch, a count
/// per method and client, never what a call said. The counts stay on the machine; Reports ▸
/// Features asks each host for them and adds them up.
public extension DaemonAPI {
    /// `reports/features`' answer: each feature with its uses in the last 7 and the last
    /// `days` days, the least used first. `since` is the first day counted.
    struct FeatureUsage: Codable, Sendable, Hashable {
        public var days: Int
        public var since: String?
        public var features: [FeatureUse]

        public init(days: Int, since: String? = nil, features: [FeatureUse]) {
            self.days = days
            self.since = since
            self.features = features
        }
    }

    /// One feature's uses. `clients` is who used it: mac, remote, web, agent or workflow.
    struct FeatureUse: Codable, Sendable, Hashable, Identifiable {
        public var method: String
        public var week: Int
        public var quarter: Int
        public var clients: [String]
        public var lastUsed: String?

        public var id: String { method }

        public init(method: String, week: Int, quarter: Int, clients: [String], lastUsed: String? = nil) {
            self.method = method
            self.week = week
            self.quarter = quarter
            self.clients = clients
            self.lastUsed = lastUsed
        }
    }
}

public extension DaemonAPI.FeatureUsage {
    /// Every host's counts as one (#2165): a feature's uses added up, its clients joined, its
    /// last use the latest, and the earliest first day; the least used first, as each host sorts.
    static func merged(_ all: [DaemonAPI.FeatureUsage]) -> DaemonAPI.FeatureUsage {
        var byMethod: [String: DaemonAPI.FeatureUse] = [:]
        for usage in all {
            for f in usage.features {
                var m = byMethod[f.method] ?? DaemonAPI.FeatureUse(method: f.method, week: 0, quarter: 0, clients: [])
                m.week += f.week
                m.quarter += f.quarter
                m.clients = Array(Set(m.clients).union(f.clients)).sorted()
                if let last = f.lastUsed, last > (m.lastUsed ?? "") { m.lastUsed = last }
                byMethod[f.method] = m
            }
        }
        let features = byMethod.values.sorted {
            ($0.quarter, $0.week, $0.method) < ($1.quarter, $1.week, $1.method)
        }
        return DaemonAPI.FeatureUsage(days: all.map(\.days).max() ?? 90,
                                      since: all.compactMap(\.since).min(), features: features)
    }
}

/// What Reports ▸ Features says (#2165), the same words as the web page's (`Web/src/model/features.ts`).
public enum FeatureWords {
    /// "7 this week · 30 in 90 days · mac, web".
    public static func line(_ f: DaemonAPI.FeatureUse, days: Int) -> String {
        var parts = ["\(f.week) this week", "\(f.quarter) in \(days) days"]
        if !f.clients.isEmpty { parts.append(f.clients.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// The mark of a feature with no use in the range.
    public static let unused = "Not used"

    /// No machine answered: each is from before #2165.
    public static let none = "No machine counts features yet. Update your machines to see them."

    public static func note(_ usage: DaemonAPI.FeatureUsage) -> String {
        let since = usage.since.map { " Counted since \($0)." } ?? " Nothing counted yet."
        return "Each method a client or an agent called on your machines, the least used first."
            + since + " The counts stay on your machines; what a call said is never kept."
    }
}
