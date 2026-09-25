import Foundation
import Testing
@testable import AgentsKitCore

/// Keeping what happened (042 FR-031, FR-032, R6).
@Suite("The event log")
struct EventLogTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let p = EventScope.project(folder: URL(fileURLWithPath: "/tmp/p"))
    private let q = EventScope.project(folder: URL(fileURLWithPath: "/tmp/q"))

    private func draft(_ name: String, _ scope: EventScope? = nil, _ details: [String: String] = [:],
                       at: Date? = nil) -> EventDraft {
        EventDraft(name: name, at: at ?? t0, scope: scope ?? p, sentence: name, details: details)
    }

    @discardableResult
    private func add(_ log: inout EventLog, _ draft: EventDraft, at seconds: TimeInterval = 0) -> EventLog.Appended {
        var draft = draft
        draft.at = t0.addingTimeInterval(seconds)
        return log.append(draft, position: log.head + 1, now: draft.at)
    }

    @Test func positionsOnlyGoUp() {
        var log = EventLog()
        add(&log, draft("mac.wake", .mac))
        add(&log, draft("mac.sleep", .mac), at: 1)
        add(&log, draft("branch.moved"), at: 2)
        #expect(log.events.map(\.position) == [1, 2, 3])
        #expect(log.head == 3)
    }

    @Test func theSameEventWithinAMinuteIsOneRowWithACount() {
        var log = EventLog()
        add(&log, draft("branch.moved", nil, ["branch": "main", "to": "a"]))
        let second = add(&log, draft("branch.moved", nil, ["branch": "main", "to": "a"]), at: 59)
        guard case .repeated(let event) = second else { Issue.record("not folded"); return }
        #expect(event.count == 2)
        #expect(event.position == 1)
        #expect(event.lastAt == t0.addingTimeInterval(59))
        #expect(log.events.count == 1)
    }

    @Test func theWindowRunsFromTheLastRepeat() {
        var log = EventLog()
        add(&log, draft("mac.wake", .mac))
        add(&log, draft("mac.wake", .mac), at: 50)
        add(&log, draft("mac.wake", .mac), at: 100)
        #expect(log.events.count == 1)
        #expect(log.events[0].count == 3)
        add(&log, draft("mac.wake", .mac), at: 161)
        #expect(log.events.count == 2)
    }

    @Test func differentDetailsOrScopesAreDifferentEvents() {
        var log = EventLog()
        add(&log, draft("branch.moved", nil, ["to": "a"]))
        add(&log, draft("branch.moved", nil, ["to": "b"]), at: 1)
        add(&log, draft("branch.moved", q, ["to": "b"]), at: 2)
        #expect(log.events.count == 3)
    }

    @Test func pruningDropsAWeekOld() {
        var log = EventLog()
        add(&log, draft("mac.wake", .mac))
        add(&log, draft("mac.sleep", .mac), at: EventLog.keepFor - 10)
        let pruned = log.prune(now: t0.addingTimeInterval(EventLog.keepFor + 1))
        #expect(pruned)
        #expect(log.events.map(\.name) == ["mac.sleep"])
    }

    @Test func pruningKeepsAtMostTenThousandDroppingTheOldest() {
        var log = EventLog()
        for i in 0...EventLog.maximumEvents {
            add(&log, draft("custom.n", nil, ["i": "\(i)"]), at: Double(i))
        }
        #expect(log.events.count == EventLog.maximumEvents + 1)
        log.prune(now: t0.addingTimeInterval(Double(EventLog.maximumEvents)))
        #expect(log.events.count == EventLog.maximumEvents)
        #expect(log.events.first?.position == 2)
    }

    @Test func aPageIsNewestFirstAndPagesBack() {
        var log = EventLog()
        for i in 0..<5 { add(&log, draft("custom.n", nil, ["i": "\(i)"]), at: Double(i)) }
        let first = log.query(limit: 2)
        #expect(first.events.map(\.position) == [5, 4])
        #expect(first.hasMore)
        let second = log.query(before: 4, limit: 2)
        #expect(second.events.map(\.position) == [3, 2])
        let last = log.query(before: 2, limit: 2)
        #expect(last.events.map(\.position) == [1])
        #expect(!last.hasMore)
    }

    @Test func aPageFiltersByScopeAndGroup() {
        var log = EventLog()
        add(&log, draft("mac.wake", .mac))
        add(&log, draft("person.away", .mac, ["why": "locked"]), at: 1)
        add(&log, draft("branch.moved", p), at: 2)
        add(&log, draft("branch.moved", q), at: 3)
        #expect(log.query(scopes: [.mac]).events.map(\.name) == ["person.away", "mac.wake"])
        #expect(log.query(groups: [.branches]).events.count == 2)
        #expect(log.query(scopes: [q], groups: [.branches]).events.map(\.position) == [4])
        #expect(log.query(groups: [.mac]).events.count == 2)
    }

    @Test func waitingFromAPositionSeesOnlyWhatCameAfterItInItsScopes() throws {
        var log = EventLog()
        add(&log, draft("custom.ping"))
        add(&log, draft("custom.ping", q), at: 61)
        add(&log, draft("custom.ping", nil, ["n": "2"]), at: 62)
        let ping = try EventPattern.parse("custom.ping").get()
        #expect(log.matches(after: 0, [ping], scopes: [.mac, p]).map(\.position) == [1, 3])
        #expect(log.matches(after: 1, [ping], scopes: [.mac, p]).map(\.position) == [3])
        #expect(log.matches(after: 3, [ping], scopes: [.mac, p]).isEmpty)
    }

    @Test func consequencesAttachToTheirEvent() {
        var log = EventLog()
        add(&log, draft("mac.wake", .mac))
        let agent = UUID()
        log.addConsequence(.woke(agentID: agent, title: "A"), to: 1)
        #expect(log.event(at: 1)?.consequences == [.woke(agentID: agent, title: "A")])
        #expect(log.addConsequence(.woke(agentID: agent, title: "A"), to: 9) == nil)
    }

    @Test func aLogSurvivesCoding() throws {
        var log = EventLog()
        add(&log, draft("mac.wake", .mac))
        add(&log, draft("custom.ping", nil, ["k": "v"]), at: 1)
        log.addConsequence(.refused(workflowID: "w", folder: URL(fileURLWithPath: "/tmp/p"),
                                    reason: .noTriggeringAgent), to: 2)
        let data = try JSONEncoder().encode(log)
        #expect(try JSONDecoder().decode(EventLog.self, from: data) == log)
    }

    @Test func draftsOverTheLimitsSayWhy() {
        var d = draft("custom.x")
        #expect(d.problem == nil)
        d.message = String(repeating: "m", count: 501)
        #expect(d.problem?.contains("500") == true)
        d.message = nil
        d.details = Dictionary(uniqueKeysWithValues: (0..<11).map { ("k\($0)", "v") })
        #expect(d.problem?.contains("at most 10") == true)
        d.details = ["long": String(repeating: "x", count: 201)]
        #expect(d.problem?.contains("200") == true)
        #expect(draft("Custom.X").problem != nil)
    }
}
