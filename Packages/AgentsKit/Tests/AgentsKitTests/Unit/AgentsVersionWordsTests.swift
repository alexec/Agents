import Foundation
import Testing
@testable import AgentsKitCore

/// A machine page's Agent Loops section (#5273), as `Web/test/agentsVersions.test.mjs` says it for the page.
@Suite("Agents version words")
struct AgentsVersionWordsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private let changes = DaemonAPI.AgentsChanges(base: "0.18.0", head: "0.18.1-dev.544+g8162a5a06", ahead: 544,
                                                  changes: [], complete: false)

    @Test func theVersionAndItsBuild() {
        #expect(AgentsVersionWords.parts("0.18.1-dev.544+g8162a5a06") == ("0.18.1-dev.544", "+g8162a5a06"))
        #expect(AgentsVersionWords.parts("0.18.0") == ("0.18.0", nil))
    }

    @Test func sinceWhenAndTheChangesSinceTheVersionBefore() {
        var agents = DaemonAPI.MachineAgents(host: .mac, version: "0.18.1-dev.544+g8162a5a06", since: at(11, 13, 15, 22),
                                             previous: "0.18.0", changes: changes)
        #expect(AgentsVersionWords.sinceLine(agents, calendar: calendar)
            == "since 13 Nov, 15:22 · 544 changes since 0.18.0, the version before")
        agents.changes = nil
        #expect(AgentsVersionWords.sinceLine(agents, calendar: calendar)
            == "since 13 Nov, 15:22 · the version before was 0.18.0; its changes can’t be read now")
        agents.previous = nil
        #expect(AgentsVersionWords.sinceLine(agents, calendar: calendar) == "since 13 Nov, 15:22")
        #expect(AgentsVersionWords.listHeading(changes) == "544 changes since 0.18.0 · newest first")
        #expect(AgentsVersionWords.showAll(changes) == "Show all 544")
        #expect(AgentsVersionWords.count(1) == "1 change")
    }

    @Test func theOtherMachines() {
        var other = DaemonAPI.MachineAgentsOther(host: MachineRef(rawValue: "box"), name: "linux-server", version: "0.18.0",
                                                 since: at(11, 8, 11, 2), ahead: 0, behind: 544)
        #expect(AgentsVersionWords.otherLine(other, calendar: calendar) == "0.18.0 · since 8 Nov, 11:02")
        #expect(AgentsVersionWords.behindLine(other) == "544 changes behind this one")
        #expect(AgentsVersionWords.isBehind(other))
        #expect(AgentsVersionWords.compare(from: other, to: "0.18.1-dev.544+g8162a5a06")
            == DaemonAPI.AgentsChangesRequest(base: "0.18.0", head: "0.18.1-dev.544+g8162a5a06"))
        other.ahead = 3
        other.behind = 0
        #expect(AgentsVersionWords.behindLine(other) == "3 changes ahead of this one")
        other.behind = 5
        #expect(AgentsVersionWords.behindLine(other) == "3 ahead of and 5 behind this one")
        other.ahead = nil
        #expect(AgentsVersionWords.behindLine(other) == nil)
    }

    @Test func aChangesLinkAndLabel() {
        #expect(AgentsVersionWords.link(DaemonAPI.AgentsChange(number: 5250, title: "t", sha: "abc"))?.absoluteString
            == "https://github.com/agentloops-dev/agent-loops/pull/5250")
        #expect(AgentsVersionWords.label(DaemonAPI.AgentsChange(title: "t", sha: "8162a5a06123")) == "8162a5a")
    }
}
