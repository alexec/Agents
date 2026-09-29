import Foundation
import Testing
@testable import AgentsKitCore

@Suite("The chat as asks and outcomes")
struct OutcomePageTests {
    private func ask(_ text: String) -> TranscriptItem {
        .entry(TranscriptEntry(kind: .userMessage(text)))
    }

    private func said(_ text: String) -> TranscriptItem {
        .entry(TranscriptEntry(kind: .agentMessage(messageID: nil, text: text)))
    }

    private func run(_ titles: String...) -> TranscriptItem {
        .toolRun(id: UUID(), calls: titles.map { ToolCall(toolCallID: $0, title: $0) })
    }

    private func texts(_ rows: [OutcomeRow]) -> [String] {
        rows.map { row in
            switch row {
            case .steps: return "steps \(row.stepCount)"
            case .item(.entry(let entry)): return entry.text ?? "other"
            case .item: return "run"
            }
        }
    }

    @Test func aTurnIsTheAskItsStepsAndItsLastMessage() {
        let rows = [ask("Fix it"), said("Looking."), run("Read a", "Read b"), said("Fixed.")].outcomes()
        #expect(texts(rows) == ["Fix it", "steps 3", "Fixed."])
    }

    @Test func eachTurnFoldsOnItsOwn() {
        let rows = [ask("One"), run("a"), said("Done one"), ask("Two"), said("Done two")].outcomes()
        #expect(texts(rows) == ["One", "steps 1", "Done one", "Two", "Done two"])
    }

    @Test func aTurnStillGoingShowsItsLatestMessage() {
        let rows = [ask("Go"), said("First I'll read"), run("Read a")].outcomes()
        #expect(texts(rows) == ["Go", "steps 1", "First I'll read"])
    }

    @Test func errorsAndAnswersStayOnThePage() {
        let error = TranscriptItem.entry(TranscriptEntry(kind: .notice(
            SessionNotice(severity: "error", title: "Broke"))))
        let answer = TranscriptItem.entry(TranscriptEntry(kind: .elicitationAnswered(
            id: UUID(), summary: "", answers: [ElicitationAnswer(question: "Which?", answer: "A")])))
        let rows = [ask("Go"), run("a"), answer, error, said("Done")].outcomes()
        #expect(rows.count == 5)
        #expect(texts(rows).first == "Go")
        #expect(texts(rows)[1] == "steps 1")
        #expect(texts(rows).last == "Done")
    }

    @Test func theFoldKeepsItsIdAsTheTurnGrows() {
        let first = run("a")
        let before = [ask("Go"), first].outcomes()
        let after = [ask("Go"), first, said("x"), run("b"), said("y")].outcomes()
        #expect(before[1].id == first.id)
        #expect(after[1].id == first.id)
    }
}
