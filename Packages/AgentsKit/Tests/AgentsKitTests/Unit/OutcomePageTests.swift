import Foundation
import Testing
@testable import AgentsKitCore

@Suite("The chat as asks and the last block of each")
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

    private func texts(_ items: [TranscriptItem]) -> [String] {
        items.map { item in
            switch item {
            case .entry(let entry): return entry.text ?? "other"
            case .toolRun(_, let calls): return calls.last?.title ?? ""
            }
        }
    }

    private let report = TranscriptItem.entry(TranscriptEntry(kind: .workReported(
        WorkReport(outcome: .done, message: "Fixed it", at: Date()))))

    @Test func aTurnIsTheAskAndItsLastBlock() {
        let page = [ask("Fix it"), said("Looking."), run("Read a", "Read b"), said("Fixed.")].outcomes()
        #expect(texts(page) == ["Fix it", "Fixed."])
    }

    @Test func aToolCallCanBeTheLastBlock() {
        let page = [ask("Go"), said("First I'll read"), run("Read a", "Edit b")].outcomes()
        #expect(texts(page) == ["Go", "Edit b"])
    }

    @Test func theReportIsNeverDrawn() {
        let page = [ask("Go"), run("Edit a"), said("Done."), report].outcomes()
        #expect(texts(page) == ["Go", "Done."])
        #expect(texts([ask("Go"), run("Edit a"), report].outcomes()) == ["Go", "Edit a"])
    }

    @Test func eachTurnKeepsItsOwnLastBlock() {
        let page = [ask("One"), run("a"), said("Done one"), ask("Two"), said("Done two")].outcomes()
        #expect(texts(page) == ["One", "Done one", "Two", "Done two"])
    }

    @Test func errorsAndAnswersStayOnThePage() {
        let error = TranscriptItem.entry(TranscriptEntry(kind: .notice(
            SessionNotice(severity: "error", title: "Broke"))))
        let answer = TranscriptItem.entry(TranscriptEntry(kind: .elicitationAnswered(
            id: UUID(), summary: "", answers: [ElicitationAnswer(question: "Which?", answer: "A")])))
        let page = [ask("Go"), run("a"), answer, run("b"), error, said("Done")].outcomes()
        #expect(page.count == 4)
        #expect(page[1] == answer)
        #expect(page[2] == error)
        #expect(texts(page).last == "Done")
    }
}
