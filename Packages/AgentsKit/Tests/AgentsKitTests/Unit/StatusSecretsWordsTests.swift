@testable import AgentsKitCore
import Foundation
import Testing

/// Status ▸ Secrets and Status ▸ Accounts (#4161): the same lines as `Web/src/model/statusSecrets.ts`.
struct StatusSecretsWordsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func secret(_ name: String, hint: String? = nil, op: String? = nil, minutesAgo: Double = 0,
                        created: String? = nil, backedUp: Bool? = true, agent: UUID? = nil) -> DaemonAPI.UserSecretRow {
        DaemonAPI.UserSecretRow(name: name, updated: "", machines: ["mac"], created: created, hint: hint,
                                lastOp: op.map { .init(what: $0, at: now.addingTimeInterval(-minutesAgo * 60), agent: agent) },
                                backedUp: backedUp)
    }

    @Test func secretsGoNewestFirstWithTheirLastOperation() throws {
        let lines = StatusSecretsWords.secretLines([
            secret("GITHUB_TOKEN", hint: "ab12", op: "read", minutesAgo: 120),
            secret("OPENAI_API_KEY", hint: "Zq9w", op: "read", minutesAgo: 5, backedUp: false),
            secret("NPM_PIN", created: "2026-01-02T03:04:05Z"),
            secret("NEVER"),
        ])
        try #require(lines.map(\.title) == ["OPENAI_API_KEY", "GITHUB_TOKEN", "NPM_PIN", "NEVER"])
        #expect(lines[0].hint == "••••Zq9w")
        #expect(lines[0].operation == "Read")
        #expect(lines[0].backedUp == false)
        #expect(lines[2].hint == "••••")
        #expect(lines[2].operation == "Added")
        #expect(lines[3].operation == nil && lines[3].at == nil)
        #expect(StatusSecretsWords.newest(lines) == now.addingTimeInterval(-300))
        #expect(StatusSecretsWords.summary(lines[1]) == "••••ab12 · Read")
    }

    @Test func anAccountTakesTheNewestOfItsOwnAndItsSecretsOperations() throws {
        let secrets = [secret("GITLAB_TOKEN", hint: "ab12", op: "read", minutesAgo: 10, backedUp: false)]
        var gitlab = DaemonAPI.OutsideAccount(service: "gitlab.com", address: "agentstest@example.com", secret: "GITLAB_TOKEN",
                                              made: "2026-01-01")
        gitlab.edited = now.addingTimeInterval(-3600)
        let slack = DaemonAPI.OutsideAccount(service: "slack.com", made: "2025-12-01")
        let aws = DaemonAPI.OutsideAccount(service: "aws.amazon.com", secret: "ELSEWHERE")
        let lines = StatusSecretsWords.accountLines([slack, aws, gitlab], secrets: secrets)
        try #require(lines.map(\.title) == ["gitlab.com", "slack.com", "aws.amazon.com"])
        #expect(lines[0].operation == "GITLAB_TOKEN read")
        #expect(lines[0].hint == "••••ab12")
        #expect(lines[0].backedUp == false)
        #expect(StatusSecretsWords.summary(lines[0]) == "agentstest@example.com · ••••ab12 · GITLAB_TOKEN read")
        #expect(lines[1].hint == "no secret" && lines[1].operation == "Added")
        #expect(lines[2].hint == "not in Secrets" && lines[2].backedUp)
    }

    @Test func theGreyLineNamesARecentReadOnly() {
        let read = StatusSecretsWords.secretLines([secret("GITHUB_TOKEN", op: "read", minutesAgo: 5),
                                                   secret("OLD", op: "replaced", minutesAgo: 60)])
        #expect(StatusSecretsWords.recentRead(read, now: now) == "GITHUB_TOKEN")
        let within = StatusSecretsWords.secretLines([secret("GITHUB_TOKEN", op: "read", minutesAgo: 3 * 60)])
        #expect(StatusSecretsWords.recentRead(within, now: now) == "GITHUB_TOKEN")
        let stale = StatusSecretsWords.secretLines([secret("GITHUB_TOKEN", op: "read", minutesAgo: 5 * 60)])
        #expect(StatusSecretsWords.recentRead(stale, now: now) == nil)
        let replaced = StatusSecretsWords.secretLines([secret("GITHUB_TOKEN", op: "read", minutesAgo: 60),
                                                       secret("NEW", op: "replaced", minutesAgo: 5)])
        #expect(StatusSecretsWords.recentRead(replaced, now: now) == nil)
        let gitlab = DaemonAPI.OutsideAccount(service: "gitlab.com", address: "agentstest@example.com", secret: "GITLAB_TOKEN")
        let accounts = StatusSecretsWords.accountLines([gitlab], secrets: [secret("GITLAB_TOKEN", op: "read", minutesAgo: 10)])
        #expect(StatusSecretsWords.recentRead(accounts, now: now) == "gitlab.com · agentstest@example.com")
    }

    @Test func theGreyLineNamesTheSessionThatReadIt() {
        let fixer = UUID(), gone = UUID()
        let titles = [fixer: "Fix the login"]
        let read = StatusSecretsWords.secretLines([secret("GITHUB_TOKEN", op: "read", minutesAgo: 5, agent: fixer)])
        #expect(StatusSecretsWords.recentRead(read, now: now) { titles[$0] } == "GITHUB_TOKEN · Fix the login")
        let unknown = StatusSecretsWords.secretLines([secret("GITHUB_TOKEN", op: "read", minutesAgo: 5, agent: gone)])
        #expect(StatusSecretsWords.recentRead(unknown, now: now) { titles[$0] } == "GITHUB_TOKEN")
        let gitlab = DaemonAPI.OutsideAccount(service: "gitlab.com", secret: "GITLAB_TOKEN")
        let accounts = StatusSecretsWords.accountLines([gitlab], secrets: [secret("GITLAB_TOKEN", op: "read", minutesAgo: 10, agent: fixer)])
        #expect(StatusSecretsWords.recentRead(accounts, now: now) { titles[$0] } == "gitlab.com · Fix the login")
    }

    @Test func agesAreShort() {
        #expect(StatusSecretsWords.ago(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(StatusSecretsWords.ago(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(StatusSecretsWords.ago(now.addingTimeInterval(-7200), now: now) == "2 h ago")
        #expect(StatusSecretsWords.ago(now.addingTimeInterval(-3 * 86_400), now: now) == "3 d ago")
    }
}
