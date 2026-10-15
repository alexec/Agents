import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The Time page's daily recap and records (#985): what the ledger notes as agents run,
/// what `gh` said about merged pull requests, and what the page reads from them.
@Suite("Time recap and records")
struct TimeRecapTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsTimeRecapTests-\(UUID().uuidString)", isDirectory: true))
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

    private func done(_ id: String, _ time: String) -> TranscriptEntry {
        TranscriptEntry(at: at(time), kind: .toolCallUpdate(ToolCall(toolCallID: id, title: "Tool call", status: "completed")))
    }

    @Test("agents at once, agents run, and the longest stretch with nobody waited for")
    func theLedgerNotesTheDay() throws {
        let ledger = TimeLedger(locations: temporary())
        let (a, b) = (UUID(), UUID())
        ledger.note(state(.running, "2026-10-12 10:00:00"), agentID: a, runtime: "claude")
        ledger.note(state(.running, "2026-10-12 10:10:00"), agentID: b, runtime: "claude")
        // b asks at 10:30: the stretch from 10:00 ends there.
        ledger.note(call("q", "AskUserQuestion", "2026-10-12 10:30:00"), agentID: b, runtime: "claude")
        ledger.note(done("q", "2026-10-12 10:35:00"), agentID: b, runtime: "claude")
        ledger.note(state(.finished, "2026-10-12 10:40:00"), agentID: b, runtime: "claude")
        // a runs on alone from 10:35, so the stretch still going counts to now.
        ledger.note(state(.running, "2026-10-12 10:50:00"), agentID: a, runtime: "claude")

        let history = ledger.history(at: at("2026-10-12 11:35:00"))
        let day = try #require(history.recap["2026-10-12"])
        #expect(day.agents == 2)
        #expect(day.peakAgents == 2)
        #expect(day.longestClear == 3600)
        #expect(history.records.mostAgents == TimeRecord(value: 2, day: "2026-10-12"))
        #expect(history.records.longestClear?.value == 3600)
    }

    @Test("an agent that runs twice in a day counts once, and waiting on its state ends a stretch")
    func oneAgentTwiceAndWaitingState() throws {
        let ledger = TimeLedger(locations: temporary())
        let a = UUID()
        ledger.note(state(.running, "2026-10-12 09:00:00"), agentID: a, runtime: "codex")
        ledger.note(state(.waitingOnUser, "2026-10-12 09:20:00"), agentID: a, runtime: "codex")
        ledger.note(state(.running, "2026-10-12 09:30:00"), agentID: a, runtime: "codex")
        ledger.note(state(.finished, "2026-10-12 09:40:00"), agentID: a, runtime: "codex")
        ledger.note(state(.running, "2026-10-12 12:00:00"), agentID: a, runtime: "codex")
        ledger.note(state(.finished, "2026-10-12 12:05:00"), agentID: a, runtime: "codex")

        let day = try #require(ledger.history(at: at("2026-10-12 13:00:00")).recap["2026-10-12"])
        #expect(day.agents == 1)
        #expect(day.peakAgents == 1)
        #expect(day.longestClear == 20 * 60)
    }

    @Test("records beat only by more, and outlive the days they came from")
    func recordsOutliveTheDays() {
        var history = TimeHistory()
        history.changeRecap("2026-01-01") { $0.peakAgents = 5 }
        history.changeRecap("2026-01-02") { $0.peakAgents = 5 }
        history.setPRsMerged(["2026-01-03": 7], on: ["2026-01-03", "2026-01-04"])
        #expect(history.records.mostAgents == TimeRecord(value: 5, day: "2026-01-01"))
        #expect(history.records.mostPRs == TimeRecord(value: 7, day: "2026-01-03"))
        #expect(history.recap["2026-01-04"]?.prsMerged == 0)

        for n in 0..<120 {
            let day = UsageChart.dayStamp(Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 86_400))
            history.changeRecap(day) { $0.agents = 1 }
        }
        history.prune()
        #expect(history.recap.count == UsageHistory.daysKept)
        #expect(history.records.mostAgents?.value == 5)
    }

    @Test("a file from before the recap still reads")
    func anOlderFileReads() throws {
        let json = Data(#"{"hours":{},"days":{"2026-10-12":{"claude":{"agent":60,"tools":0,"others":0,"person":0,"turns":1}}},"now":""}"#.utf8)
        let history = try StoreCoding.decoder.decode(TimeHistory.self, from: json)
        #expect(history.recap.isEmpty)
        #expect(history.records.isEmpty)
        #expect(history.days["2026-10-12"]?["claude"]?.turns == 1)
    }

    @Test("today and the last seven days: turns, agents, pull requests, leverage and peak")
    func theRecap() {
        var history = TimeHistory(now: "2026-10-12T15")
        history.days["2026-10-12"] = ["claude": TimeBucket(agent: 3000, tools: 600, person: 1200, turns: 4),
                                      "codex": TimeBucket(agent: 600, turns: 1)]
        history.days["2026-10-08"] = ["claude": TimeBucket(agent: 6600, person: 600, turns: 2)]
        history.days["2026-10-01"] = ["claude": TimeBucket(agent: 9999, person: 1, turns: 9)]
        history.recap["2026-10-12"] = DayRecap(prsMerged: 2, agents: 3, peakAgents: 2)
        history.recap["2026-10-08"] = DayRecap(agents: 1, peakAgents: 4)
        let recap = TimeRecap(history)
        #expect(recap.today.turns == 5)
        #expect(recap.today.agents == 3)
        #expect(recap.today.prsMerged == 2)
        #expect(recap.today.leverage == 3.5)
        #expect(recap.week.turns == 7)
        #expect(recap.week.agents == 4)
        #expect(recap.week.prsMerged == 2)
        #expect(recap.week.peakAgents == 4)
        #expect(recap.week.leverage == 6)
        #expect(TimeRecap.leverageWords(3.5) == "3.5×")
        #expect(TimeRecap.leverageWords(12.4) == "12×")
        #expect(TimeRecap.leverageWords(nil) == "–")
        // No pull request figure until gh has said something.
        #expect(TimeRecap(TimeHistory(now: "2026-10-12T15")).today.prsMerged == nil)
    }

    @Test("gh's merged pull requests: only the app's branches, each once, by the host's day")
    func mergedByDay() throws {
        let json = Data("""
        [{"url":"https://github.com/o/r/pull/1","mergedAt":"2026-10-12T10:00:00Z","headRefName":"agents/work-1"},
         {"url":"https://github.com/o/r/pull/1","mergedAt":"2026-10-12T10:00:00Z","headRefName":"agents/work-1"},
         {"url":"https://github.com/o/r/pull/2","mergedAt":"2026-10-12T11:00:00Z","headRefName":"feature/mine"},
         {"url":"https://github.com/o/r/pull/3","mergedAt":"2026-10-11T11:00:00Z","headRefName":"agents/work-3"}]
        """.utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let pulls = try GitHubCLI.mergedPullRequests(from: json)
        #expect(GitHubCLI.mergedByDay(pulls, calendar: calendar) == ["2026-10-12": 1, "2026-10-11": 1])
    }
}
