import Foundation
import Testing
@testable import AgentsKit
import AgentsKitCore

@Suite("Daemon runtime stderr budget")
struct DaemonStderrBudgetTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func capsEachChunkAndEachAgentsMinute() {
        var budget = DaemonStderrBudget()
        let agent = UUID()
        let oversized = String(repeating: "x", count: 2048)

        #expect(budget.consume(oversized, from: agent, at: start) == .log(String(repeating: "x", count: 1024)))
        for _ in 0..<3 {
            #expect(budget.consume(String(repeating: "y", count: 1024), from: agent, at: start).isLogged)
        }
        #expect(budget.consume("overflow", from: agent, at: start) == .suppress(total: 1))
    }

    @Test func resetsTheByteBudgetEachMinuteAndSeparatesAgents() {
        var budget = DaemonStderrBudget()
        let first = UUID()
        let second = UUID()
        let fullMinute = String(repeating: "x", count: 1024)

        for _ in 0..<4 {
            #expect(budget.consume(fullMinute, from: first, at: start).isLogged)
        }
        #expect(budget.consume("overflow", from: first, at: start) == .suppress(total: 1))
        #expect(budget.consume("other agent", from: second, at: start).isLogged)
        #expect(budget.consume("new minute", from: first, at: start.addingTimeInterval(60)).isLogged)
    }

    @Test func aRepeatedFailureLineIsCountedInsteadOfLoggedAgain() {
        var notices = RepeatedNotice(every: 3600)
        let line = "store: could not save a line: disk full"

        #expect(notices.note(line, at: start) == .first)
        #expect(notices.note(line, at: start.addingTimeInterval(1)) == nil)
        #expect(notices.note(line, at: start.addingTimeInterval(3600)) == .again(times: 2, since: start))
    }
}

private extension DaemonStderrBudget.Decision {
    var isLogged: Bool {
        if case .log = self { return true }
        return false
    }
}
