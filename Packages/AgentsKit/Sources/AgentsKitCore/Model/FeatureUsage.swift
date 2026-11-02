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
