import Foundation
import Testing
@testable import AgentsKitCore

/// An agent's `ask_secret` (#2885), as every Swift client reads it: the secret comes off the
/// wire beside its one-field form, and nothing answers it but its masked card.
@Suite("Secret asks")
struct SecretAskTests {
    static let wire = """
        {"id":"7B0F3C1E-2D4A-4E8B-9C61-0A1B2C3D4E5F","agentID":"1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F",
         "message":"OPENAI_API_KEY","scope":"session","askedAt":"2026-10-29T12:00:00Z",
         "mode":{"form":{"_0":{"title":"OPENAI_API_KEY (a secret)","properties":[
           {"name":"value","title":"To call the embeddings API.","isRequired":true,"kind":{"string":{}}}]}}},
         "secret":{"name":"OPENAI_API_KEY","url":"https://platform.openai.com/api-keys","isSet":true}}
        """

    @Test("comes off the wire with its name, link and reason")
    func decodes() throws {
        let request = try StoreCoding.decoder.decode(ElicitationRequest.self, from: Data(Self.wire.utf8))
        #expect(request.secret == ElicitationRequest.Secret(name: "OPENAI_API_KEY",
                                                            url: "https://platform.openai.com/api-keys", isSet: true))
        #expect(request.secretReason == "To call the embeddings API.")
        #expect(ElicitationRequest.secretField == "value")
    }

    @Test("has no Reply in a notification, and voice mode says it needs the screen")
    func onlyItsCard() throws {
        let request = try StoreCoding.decoder.decode(ElicitationRequest.self, from: Data(Self.wire.utf8))
        #expect(QuickAnswer.answers(for: request) == nil)
        #expect(SpokenQuestion(request) == nil)
        var plain = request
        plain.secret = nil
        #expect(QuickAnswer.answers(for: plain)?.first?.kind == .reply)
    }

    @Test("waits on the person, as ask_question does")
    func personsTime() {
        #expect(TimeMark.kind(ofTool: "mcp__agents__ask_secret") == .person)
        #expect(AppTool.isServedByTheApp("mcp__agents__ask_secret"))
    }
}
