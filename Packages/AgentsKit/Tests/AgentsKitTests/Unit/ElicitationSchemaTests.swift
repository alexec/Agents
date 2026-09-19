import Foundation
import Testing
@testable import AgentsKit

/// No runtime on this Mac asks for a form yet. This is what "complete" means: an agent
/// that starts using it tomorrow gets an answer instead of a refusal.
@Suite("The shape of a question")
struct ElicitationSchemaTests {
    private func schema(_ properties: JSONValue, required: JSONValue = .array([])) -> ElicitationSchema? {
        ElicitationSchema(wire: ["title": "Tell me", "properties": properties, "required": required])
    }

    @Test func aStringWithAFormatIsCheckedAgainstIt() throws {
        let schema = try #require(schema(["email": ["type": "string", "format": "email"]]))
        let property = try #require(schema.properties.first)
        #expect(property.problem(with: .string("alex@example.com")) == nil)
        #expect(property.problem(with: .string("not an email")) != nil)
    }

    @Test func lengthsAreChecked() throws {
        let schema = try #require(schema(["name": ["type": "string", "minLength": 2, "maxLength": 4]]))
        let property = try #require(schema.properties.first)
        #expect(property.problem(with: .string("a")) == "At least 2 characters")
        #expect(property.problem(with: .string("abcde")) == "At most 4 characters")
        #expect(property.problem(with: .string("abc")) == nil)
    }

    @Test func aNumberIsCheckedAgainstItsRange() throws {
        let schema = try #require(schema(["how_many": ["type": "number", "minimum": 1, "maximum": 10]]))
        let property = try #require(schema.properties.first)
        #expect(property.problem(with: .double(0.5)) == "At least 1.0")
        #expect(property.problem(with: .double(11)) == "At most 10.0")
        #expect(property.problem(with: .double(5)) == nil)
    }

    @Test func aWholeNumberWillNotTakeAFraction() throws {
        let schema = try #require(schema(["count": ["type": "integer", "minimum": 0]]))
        let property = try #require(schema.properties.first)
        #expect(property.problem(with: .double(1.5)) != nil)
        #expect(property.problem(with: .int(2)) == nil)
    }

    @Test func aChoiceMustBeOneOfTheChoices() throws {
        let schema = try #require(schema(["colour": ["type": "string",
                                                     "enum": ["red", "green"]]]))
        let property = try #require(schema.properties.first)
        #expect(property.problem(with: .string("red")) == nil)
        #expect(property.problem(with: .string("blue")) == "Not one of the choices")
    }

    @Test func aMultiSelectIsCountedAndChecked() throws {
        let schema = try #require(schema(["tags": ["type": "array",
                                                   "items": ["enum": ["a", "b", "c"]],
                                                   "minItems": 1, "maxItems": 2]]))
        let property = try #require(schema.properties.first)
        #expect(property.problem(with: .array([])) == nil, "empty is missing, not wrong, when optional")
        #expect(property.problem(with: .array([.string("a"), .string("b"), .string("c")])) == "Choose at most 2")
        #expect(property.problem(with: .array([.string("z")])) == "Not one of the choices")
        #expect(property.problem(with: .array([.string("a")])) == nil)
    }

    @Test func somethingRequiredIsMissedWhenItIsMissing() throws {
        let schema = try #require(schema(["name": ["type": "string", "title": "Your name"]],
                                         required: ["name"]))
        #expect(schema.problems(with: [:]) == ["Your name is needed"])
        #expect(schema.problems(with: ["name": .string("Alex")]).isEmpty)
    }

    @Test func aPropertyWeCannotDrawMakesTheWholeFormUndrawable() {
        // Declined rather than half-answered: the agent asked for something specific.
        #expect(schema(["mystery": ["type": "hologram"]]) == nil)
        #expect(schema(["fine": ["type": "string"], "mystery": ["type": "hologram"]]) == nil)
    }

    @Test func aFormWithNoPropertiesIsNotAForm() {
        #expect(ElicitationSchema(wire: ["properties": .object([:])]) == nil)
        #expect(ElicitationSchema(wire: nil) == nil)
    }

    @Test func aRequestIsEitherAFormOrALink() {
        let agentID = UUID()
        let form = ElicitationRequest(wire: ["schema": ["properties": ["a": ["type": "string"]]]],
                                      agentID: agentID)
        guard case .form? = form?.mode else {
            Issue.record("expected a form")
            return
        }
        let link = ElicitationRequest(wire: ["url": "https://example.com/authorise",
                                             "description": "Say yes over there"],
                                      agentID: agentID)
        guard case .url(let url, let description)? = link?.mode else {
            Issue.record("expected a link")
            return
        }
        #expect(url == "https://example.com/authorise")
        #expect(description == "Say yes over there")
        #expect(ElicitationRequest(wire: ["nothing": true], agentID: agentID) == nil)
    }

    @Test func anAnswerSaysWhatWasDone() {
        #expect(ElicitationOutcome.accept(["a": "b"]).wire["action"]?.stringValue == "accept")
        #expect(ElicitationOutcome.decline.wire["action"]?.stringValue == "decline")
        #expect(ElicitationOutcome.cancel.wire["action"]?.stringValue == "cancel")
    }
}
