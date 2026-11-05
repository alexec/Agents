import Foundation
import Testing
@testable import AgentsKitCore

/// An agent's `hand_to_person` (#3529), as every Swift client reads it: the step and why
/// beside a one-choice form, Done or Can't do it, which a phone and a notification answer
/// as any other question.
@Suite("Hand-offs")
struct HandOffTests {
    static let wire = """
        {"id":"7B0F3C1E-2D4A-4E8B-9C61-0A1B2C3D4E5F","agentID":"1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F",
         "message":"Solve the CAPTCHA","scope":"session","askedAt":"2026-11-05T12:00:00Z",
         "mode":{"form":{"_0":{"description":"The sign-up form needs a person.","properties":[
           {"name":"outcome","isRequired":true,"kind":{"string":{"choices":[
             {"value":"done","title":"Done"},{"value":"cannot","title":"Can't do it"}]}}},
           {"name":"outcome_note","title":"What stopped you (optional)","isRequired":false,"kind":{"string":{}}}]}}},
         "handOff":{"step":"Solve the CAPTCHA","reason":"The sign-up form needs a person."}}
        """

    @Test("comes off the wire with its step and reason")
    func decodes() throws {
        let request = try StoreCoding.decoder.decode(ElicitationRequest.self, from: Data(Self.wire.utf8))
        #expect(request.handOff == ElicitationRequest.HandOff(step: "Solve the CAPTCHA", reason: "The sign-up form needs a person."))
        #expect(request.title == "Solve the CAPTCHA")
        #expect(request.secret == nil)
    }

    @Test("is answered in one tap from a notification")
    func quickAnswers() throws {
        let request = try StoreCoding.decoder.decode(ElicitationRequest.self, from: Data(Self.wire.utf8))
        #expect(QuickAnswer.answers(for: request)?.map(\.title) == ["Done", "Can't do it"])
    }

    @Test("waits on the person")
    func personsTime() {
        #expect(TimeMark.kind(ofTool: "mcp__agents__hand_to_person") == .person)
    }
}
