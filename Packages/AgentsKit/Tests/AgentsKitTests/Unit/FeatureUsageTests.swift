import Testing
@testable import AgentsKitCore

/// Reports ▸ Features (#2165): every host's counts as one, and the words the web page says too.
@Suite("Feature usage")
struct FeatureUsageTests {
    typealias Use = DaemonAPI.FeatureUse

    @Test func hostsAreAddedUpTheLeastUsedFirst() throws {
        let mac = DaemonAPI.FeatureUsage(days: 90, since: "2026-09-01", features: [
            Use(method: "workflows/run", week: 0, quarter: 0, clients: []),
            Use(method: "sessions/start", week: 2, quarter: 5, clients: ["mac"], lastUsed: "2026-10-29"),
        ])
        let server = DaemonAPI.FeatureUsage(days: 90, since: "2026-08-15", features: [
            Use(method: "sessions/start", week: 1, quarter: 1, clients: ["agent", "mac"], lastUsed: "2026-10-30"),
            Use(method: "files/read", week: 1, quarter: 2, clients: ["web"], lastUsed: "2026-10-01"),
        ])
        let all = DaemonAPI.FeatureUsage.merged([mac, server])
        #expect(all.since == "2026-08-15")
        #expect(all.features.map(\.method) == ["workflows/run", "files/read", "sessions/start"])
        let most = try #require(all.features.last)
        #expect(most == Use(method: "sessions/start", week: 3, quarter: 6, clients: ["agent", "mac"], lastUsed: "2026-10-30"))
    }

    @Test func aLineSaysTheUsesAndTheClients() {
        #expect(FeatureWords.line(Use(method: "m", week: 7, quarter: 30, clients: ["mac", "web"]), days: 90)
            == "7 this week · 30 in 90 days · mac, web")
        #expect(FeatureWords.line(Use(method: "m", week: 0, quarter: 0, clients: []), days: 90) == "0 this week · 0 in 90 days")
    }
}
