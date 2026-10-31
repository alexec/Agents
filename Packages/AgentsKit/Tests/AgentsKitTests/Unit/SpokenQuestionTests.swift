import Foundation
import Testing
@testable import AgentsKitCore

/// #2322: a question card read out with numbers, and answered by voice.
@Suite("A question is read out and answered by voice")
struct SpokenQuestionTests {
    private func question(_ titles: [String], message: String = "Where should the token go?") -> ElicitationRequest {
        let choices = titles.map { ElicitationSchema.Property.Choice(value: $0.lowercased(), title: $0) }
        let property = ElicitationSchema.Property(name: "question_0", title: "Token store", kind: .string(format: nil, minLength: nil, maxLength: nil, choices: choices))
        let note = ElicitationSchema.Property(name: "question_0_custom", description: "Add to your selection above",
                                              kind: .string(format: nil, minLength: nil, maxLength: nil, choices: nil))
        return ElicitationRequest(agentID: UUID(), message: message, mode: .form(ElicitationSchema(properties: [property, note])))
    }

    /// The card's question is the message; the field's title is only its heading.
    @Test func theChoicesAreReadWithNumbers() throws {
        let spoken = try #require(SpokenQuestion(question(["Keychain (Recommended)", "File"])))
        #expect(spoken.sentences == ["Where should the token go?", "Two choices.", "One: Keychain.", "Two: File.", "One is recommended."])
        #expect(spoken.property == "question_0")
    }

    @Test func aNumberOrTheWordsPickAChoice() throws {
        let spoken = try #require(SpokenQuestion(question(["Keychain (Recommended)", "File", "Ask me later"])))
        #expect(spoken.choice(for: "Two.")?.value == "file")
        #expect(spoken.choice(for: "The second one")?.value == "file")
        #expect(spoken.choice(for: "option 3")?.value == "ask me later")
        #expect(spoken.choice(for: "Put it in the keychain please")?.value == "keychain (recommended)")
        #expect(spoken.choice(for: "to")?.value == "file")
        #expect(spoken.choice(for: "go to the shop") == nil)
        #expect(spoken.choice(for: "seven") == nil)
        #expect(spoken.choice(for: "") == nil)
    }

    @Test func noTakesItBack() {
        #expect(SpokenQuestion.isNo("No, wait"))
        #expect(SpokenQuestion.isNo("stop"))
        #expect(!SpokenQuestion.isNo("Yes"))
    }

    @Test func aFormOfSeveralQuestionsNeedsTheScreen() {
        let a = ElicitationSchema.Property(name: "a", kind: .boolean)
        let b = ElicitationSchema.Property(name: "b", kind: .integer(minimum: nil, maximum: nil))
        #expect(SpokenQuestion(ElicitationRequest(agentID: UUID(), mode: .form(ElicitationSchema(properties: [a, b])))) == nil)
        #expect(SpokenQuestion(ElicitationRequest(agentID: UUID(), mode: .url("https://example.com"))) == nil)
    }
}
