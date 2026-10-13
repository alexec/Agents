import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Where the time of running chats went (#852): split by kind, banked by the hour, and
/// seeded once.
@Suite("Where chat time went")
struct TimeHistoryTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsTimeHistoryTests-\(UUID().uuidString)", isDirectory: true))
    }

    private func at(_ text: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f.date(from: text)!
    }

    private func state(_ s: AgentState, _ time: String) -> TranscriptEntry {
        TranscriptEntry(at: at(time), kind: .stateChanged(s, reason: s == .finished ? .endTurn : nil))
    }

    private func call(_ id: String, _ name: String, _ time: String) -> TranscriptEntry {
        TranscriptEntry(at: at(time), kind: .toolCall(ToolCall(toolCallID: id, title: name, name: name, status: "pending")))
    }

    private func done(_ id: String, _ time: String, status: String = "completed") -> TranscriptEntry {
        TranscriptEntry(at: at(time), kind: .toolCallUpdate(ToolCall(toolCallID: id, title: "Tool call", status: status)))
    }

    private func split(_ entries: [TranscriptEntry]) -> TimeBucket {
        var bucket = TimeBucket()
        for segment in TimeMark.segments(entries.compactMap(TimeMark.of)) { bucket[segment.kind] += segment.seconds }
        return bucket
    }

    @Test("running time is the agent's, less its tool calls; overlapping calls count once")
    func toolsAndAgent() {
        let time = split([
            state(.running, "2026-10-12 10:00:00"),
            call("a", "Bash", "2026-10-12 10:00:10"),
            call("b", "Read", "2026-10-12 10:00:20"),
            done("a", "2026-10-12 10:00:40"),
            done("b", "2026-10-12 10:00:50", status: "failed"),
            state(.finished, "2026-10-12 10:01:00"),
        ])
        #expect(time.tools == 40)
        #expect(time.agent == 20)
        #expect(time.person == 0 && time.others == 0)
    }

    @Test("an ask is the person's time and a wait is others', whatever the runtime calls it")
    func asksAndWaits() {
        let time = split([
            state(.running, "2026-10-12 10:00:00"),
            call("q", "AskUserQuestion", "2026-10-12 10:00:00"),
            done("q", "2026-10-12 10:05:00"),
            call("w", "mcp__agents__wait_for_event", "2026-10-12 10:05:00"),
            done("w", "2026-10-12 10:06:00"),
            call("l", "mcp.agents.lease_resource", "2026-10-12 10:06:00"),
            done("l", "2026-10-12 10:06:30"),
            call("r", "agents_release_resource", "2026-10-12 10:06:30"),
            done("r", "2026-10-12 10:06:31"),
            call("f", "agents_ask_form", "2026-10-12 10:06:31"),
            done("f", "2026-10-12 10:07:31"),
            state(.finished, "2026-10-12 10:08:00"),
        ])
        #expect(time.person == 360)
        #expect(time.others == 90)
        #expect(time.tools == 1, "a release is quick, and not a wait")
        #expect(time.agent == 29)
    }

    @Test("waiting on the person comes first, even with a tool open beneath it")
    func waitingOnUserWins() {
        let time = split([
            state(.running, "2026-10-12 10:00:00"),
            call("a", "Bash", "2026-10-12 10:00:00"),
            state(.waitingOnUser, "2026-10-12 10:00:10"),
            state(.running, "2026-10-12 10:01:10"),
            done("a", "2026-10-12 10:01:20"),
            state(.finished, "2026-10-12 10:01:30"),
        ])
        #expect(time.person == 60)
        #expect(time.tools == 20)
        #expect(time.agent == 10)
    }

    @Test("a call left open closes with the turn, and nothing is counted after it")
    func openCallsCloseAtTheEnd() {
        let time = split([
            state(.running, "2026-10-12 10:00:00"),
            call("a", "Bash", "2026-10-12 10:00:30"),
            state(.stopped, "2026-10-12 10:01:00"),
            done("a", "2026-10-12 10:30:00"),
        ])
        #expect(time.agent == 30)
        #expect(time.tools == 30)
    }

    @Test("a turn is banked when it ends, split across the hours it ran in")
    func aTurnIsBankedByTheHour() throws {
        let locations = temporary()
        let ledger = TimeLedger(locations: locations, now: at("2026-10-12 09:00:00"))
        let id = UUID()
        let entries = [
            state(.running, "2026-10-12 10:50:00"),
            call("a", "Bash", "2026-10-12 10:55:00"),
            done("a", "2026-10-12 11:05:00"),
            state(.finished, "2026-10-12 11:10:00"),
        ]
        let banked = entries.map { ledger.note($0, agentID: id, runtime: "claude") }
        #expect(banked == [false, false, false, true])
        try ledger.flush()

        let history = TimeLedger(locations: locations).history(at: at("2026-10-12 12:00:00"))
        #expect(history.hours["2026-10-12T10"]?["claude"] == TimeBucket(agent: 300, tools: 300))
        #expect(history.hours["2026-10-12T11"]?["claude"] == TimeBucket(agent: 300, tools: 300, turns: 1))
        #expect(history.days["2026-10-12"]?["claude"] == TimeBucket(agent: 600, tools: 600, turns: 1))
    }

    @Test("nothing outside a turn is counted, and a very long turn is banked in parts")
    func outsideAndLongTurns() throws {
        let locations = temporary()
        let ledger = TimeLedger(locations: locations)
        let id = UUID()
        ledger.note(call("x", "Bash", "2026-10-12 09:00:00"), agentID: id, runtime: "codex")
        ledger.note(state(.running, "2026-10-12 10:00:00"), agentID: id, runtime: "codex")
        ledger.note(call("open", "Bash", "2026-10-12 10:00:00"), agentID: id, runtime: "codex")
        var clock = at("2026-10-12 10:00:00")
        for n in 0..<(TimeLedger.marksKept + 10) {
            clock = clock.addingTimeInterval(1)
            ledger.note(TranscriptEntry(at: clock, kind: .toolCall(ToolCall(toolCallID: "c\(n)", title: "Read"))),
                        agentID: id, runtime: "codex")
        }
        clock = clock.addingTimeInterval(1)
        ledger.note(TranscriptEntry(at: clock, kind: .stateChanged(.finished, reason: .endTurn)), agentID: id, runtime: "codex")
        try ledger.flush()
        let day = TimeLedger(locations: locations).history(at: clock).days["2026-10-12"]?["codex"]
        #expect(day?.tools == clock.timeIntervalSince(at("2026-10-12 10:00:00")),
                "the call open across the cut is counted on both sides of it, once")
        #expect(day?.turns == 1)
    }

    @Test("the file never holds more than 168 hours and 90 days")
    func theHistoryIsBounded() {
        var history = TimeHistory()
        var date = at("2026-06-01 00:00:00")
        for _ in 0..<(120 * 4) {
            history.add(.agent, from: date, to: date.addingTimeInterval(60), runtime: "claude")
            date = date.addingTimeInterval(6 * 3600)
        }
        history.prune()
        #expect(history.hours.count == UsageHistory.hoursKept)
        #expect(history.days.count == UsageHistory.daysKept)
    }

    @Test("a first run is seeded from the transcripts made before it")
    func aFirstRunIsSeeded() throws {
        let locations = temporary()
        let id = UUID()
        try FileManager.default.createDirectory(at: locations.agent(id), withIntermediateDirectories: true)
        try Data(#"{"runtimeID":"grok"}"#.utf8).write(to: locations.record(id))
        let entries = [
            state(.running, "2026-10-11 10:00:00"),
            call("a", "Bash", "2026-10-11 10:00:10"),
            TranscriptEntry(at: at("2026-10-11 10:00:20"), kind: .toolCallUpdate(ToolCall(toolCallID: "a", title: "Bash", status: "in_progress"))),
            done("a", "2026-10-11 10:00:40"),
            state(.finished, "2026-10-11 10:01:00"),
            // After the ledger was made: the daemon notes these itself.
            state(.running, "2026-10-12 12:00:00"),
            state(.finished, "2026-10-12 12:10:00"),
        ]
        let lines = try entries.map { String(decoding: try StoreCoding.encoder.encode($0), as: UTF8.self) }
        try Data(lines.joined(separator: "\n").utf8).write(to: locations.transcript(id))

        let ledger = TimeLedger(locations: locations, now: at("2026-10-12 11:00:00"))
        ledger.seedIfNeeded()
        let history = TimeLedger(locations: locations).history(at: at("2026-10-12 13:00:00"))
        #expect(history.days["2026-10-11"]?["grok"] == TimeBucket(agent: 30, tools: 30, turns: 1))
        #expect(history.days["2026-10-12"] == nil)
        #expect(history.hours["2026-10-11T10"]?["grok"]?.turns == 1)
    }

    @Test("the chart stacks each bar by kind and averages over the days with time")
    func theChart() throws {
        var history = TimeHistory(now: "2026-10-12T15")
        history.add(TimeBucket(agent: 3600, tools: 1800, turns: 2), runtime: "claude", hour: "2026-10-12T09")
        history.add(TimeBucket(person: 600, turns: 1), runtime: "codex", hour: "2026-10-10T09")
        let week = TimeChart(history, range: .week)
        #expect(week.bars.count == 7)
        #expect(week.bars.last?.time.agent == 3600)
        #expect(week.time.total == 6000)
        #expect(week.average == 3000)
        #expect(week.shares.map(\.runtime) == ["claude", "codex"])
        #expect(week.percent(week.time.person) == "10%")
        let day = TimeChart(history, range: .day)
        try #require(day.bars.count == 24)
        #expect(day.bars[9].total == 5400)
        #expect(day.average == 5400)
    }

    @Test("times read at a glance")
    func words() {
        #expect(TimeChart.words(42) == "42s")
        #expect(TimeChart.words(12 * 60) == "12m")
        #expect(TimeChart.words(3 * 3600 + 20 * 60) == "3h 20m")
        #expect(TimeChart.words(2 * 3600) == "2h")
        #expect(TimeChart.words(140 * 3600 + 59) == "140h")
    }
}
