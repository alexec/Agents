import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Reading a typed failure and Claude's plan window off `_meta` (052, R1–R3). The
/// fixtures are the adapters' own shapes; their README says where each came from.
@Suite("Reading a typed failure")
struct SessionFailureDecodingTests {
    static func fixture(_ name: String) throws -> JSONValue {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()      // Unit
            .deletingLastPathComponent()      // AgentsKitTests
            .appending(path: "Fixtures/session-failures/\(name).json")
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    @Test(arguments: [
        ("quota-exhausted", "limit", [String](), "error"),
        ("rate-limited", "limit", ["retry"], "error"),
        ("budget-exhausted", "limit", ["new_session"], "error"),
        ("auth-required", "access", ["login"], "error"),
        ("overloaded", "service", ["retry"], "error"),
        ("retry-warning", "service", ["retry"], "warning"),
    ])
    func eachKindIsReadAsSent(name: String, category: String, actions: [String], severity: String) throws {
        let failure = try #require(SessionFailure.from(meta: Self.fixture(name)))
        #expect(failure.category == category)
        #expect(failure.actions == actions)
        #expect(failure.severity == severity)
        #expect(failure.isError == (severity == "error"))
        #expect(!failure.title.isEmpty)
    }

    @Test func somethingNewIsKeptAsItCame() throws {
        let failure = try #require(SessionFailure.from(meta: Self.fixture("unknown-category")))
        #expect(failure.category == "somethingNew")
        #expect(failure.actions == ["dance"])
        #expect(failure.isError)
    }

    @Test func noFailureMeansNil() {
        #expect(SessionFailure.from(meta: nil) == nil)
        #expect(SessionFailure.from(meta: ["quota": ["token_count": [:]]]) == nil)
        #expect(SessionFailure.from(meta: ["jetbrains": ["air": ["version": 1]]]) == nil)
        // Half a failure is no failure: without a title there is nothing to show.
        #expect(SessionFailure.from(meta: ["jetbrains": ["air": ["sessionFailure": ["id": "x", "category": "limit"]]]]) == nil)
    }

    @Test func aLaterRevisionReplacesAnEarlierOne() {
        let first = SessionFailure(id: "t:error", revision: 1, category: "limit", title: "one")
        let second = SessionFailure(id: "t:error", revision: 2, category: "limit", title: "two")
        let other = SessionFailure(id: "u:error", revision: 1, category: "service", title: "three")
        #expect(first.superseded(by: second).title == "two")
        #expect(second.superseded(by: first).title == "two")
        #expect(first.superseded(by: other).title == "three")
    }

    @Test func claudesPlanWindowIsRead() throws {
        let info = try #require(RateLimitInfo.from(meta: Self.fixture("claude-rate-limit-rejected")))
        #expect(info.isRejected)
        #expect(info.resetsAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(info.rateLimitType == "five_hour")
        #expect(!info.isPayingOverage)
    }

    @Test func paidOverageIsSeen() throws {
        let info = try #require(RateLimitInfo.from(meta: Self.fixture("claude-rate-limit-overage")))
        #expect(!info.isRejected)
        #expect(info.isPayingOverage)
        #expect(info.utilization == 1.02)
    }

    @Test func noPlanWindowMeansNil() {
        #expect(RateLimitInfo.from(meta: nil) == nil)
        #expect(RateLimitInfo.from(meta: ["_claude/rateLimit": "nonsense"]) == nil)
    }

    @Test func aUsageUpdateKeepsThePlanWindow() throws {
        let update: [String: JSONValue] = ["sessionUpdate": "usage_update", "used": 10, "size": 100,
                                           "_meta": try Self.fixture("claude-rate-limit-rejected")]
        guard case .usage(let usage) = SessionUpdate.decode(.object(update)) else {
            Issue.record("not a usage update"); return
        }
        #expect(usage.rateLimit?.isRejected == true)
    }

    @Test func aSessionInfoUpdateWithAFailureIsNotIgnored() throws {
        let update: JSONValue = ["sessionUpdate": "session_info_update",
                                 "_meta": try Self.fixture("quota-exhausted")]
        guard case .failure(let failure, let title) = SessionUpdate.decode(update) else {
            Issue.record("the failure was dropped"); return
        }
        #expect(failure.category == "limit")
        #expect(title == nil)
    }
}
