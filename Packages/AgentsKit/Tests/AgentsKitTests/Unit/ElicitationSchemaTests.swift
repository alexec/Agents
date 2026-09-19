import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

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

    /// A titled option names its value `const`, not `value`, and carries the sentence
    /// that says what picking it means. Reading it as `value` left the field a text box.
    @Test func aTitledChoiceIsReadFromItsConst() throws {
        let schema = try #require(schema(["colour": ["type": "string",
                                                     "oneOf": [["const": "red", "title": "Red",
                                                                "description": "Like a tomato"],
                                                               ["const": "green", "title": "Green"]]]]))
        let property = try #require(schema.properties.first)
        guard case .string(_, _, _, let choices) = property.kind, let choices else {
            Issue.record("expected choices")
            return
        }
        #expect(choices.map(\.value) == ["red", "green"])
        #expect(choices.first?.title == "Red")
        #expect(choices.first?.description == "Like a tomato")
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

    /// Titled multi-select choices hang off `items.anyOf`. Looking only under
    /// `items.enum` made the property undrawable, and one undrawable property declines
    /// the whole form.
    @Test func aTitledMultiSelectIsReadFromItsAnyOf() throws {
        let schema = try #require(schema(["tags": ["type": "array",
                                                   "items": ["anyOf": [["const": "a", "title": "Ay"],
                                                                        ["const": "b", "title": "Bee"]]]]]))
        let property = try #require(schema.properties.first)
        guard case .multiSelect(let items, _, _) = property.kind else {
            Issue.record("expected a multi-select")
            return
        }
        #expect(items.map(\.value) == ["a", "b"])
        #expect(items.first?.title == "Ay")
        #expect(property.problem(with: .array([.string("z")])) == "Not one of the choices")
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
        let form = ElicitationRequest(wire: ["message": "Which one?",
                                             "requestedSchema": ["properties": ["a": ["type": "string"]]]],
                                      agentID: agentID)
        guard case .form? = form?.mode else {
            Issue.record("expected a form")
            return
        }
        // The question itself lives in `message`: a one-question form names no field.
        #expect(form?.message == "Which one?")
        #expect(form?.title == "Which one?")
        let link = ElicitationRequest(wire: ["url": "https://example.com/authorise",
                                             "message": "Say yes over there"],
                                      agentID: agentID)
        guard case .url(let url)? = link?.mode else {
            Issue.record("expected a link")
            return
        }
        #expect(url == "https://example.com/authorise")
        #expect(link?.message == "Say yes over there")
        #expect(ElicitationRequest(wire: ["nothing": true], agentID: agentID) == nil)
    }

    /// The whole bug: the form travels as `requestedSchema`, and reading `schema`
    /// found nothing, so every question was declined before anyone saw it.
    @Test func aFormUnderTheWrongKeyIsNotAForm() {
        #expect(ElicitationRequest(wire: ["schema": ["properties": ["a": ["type": "string"]]]],
                                   agentID: UUID()) == nil)
    }

    @Test func anAnswerSaysWhatWasDone() {
        #expect(ElicitationOutcome.accept(["a": "b"]).wire["action"]?.stringValue == "accept")
        #expect(ElicitationOutcome.decline.wire["action"]?.stringValue == "decline")
        #expect(ElicitationOutcome.cancel.wire["action"]?.stringValue == "cancel")
    }

    // MARK: Which questions can be answered in one click

    /// One list of choices and nothing else: the shape that becomes buttons.
    @Test func oneListOfChoicesIsOneClick() {
        let schema = ElicitationSchema(wire: .object([
            "properties": ["colour": ["type": "string", "enum": ["red", "green"]]],
            "required": ["colour"],
        ]))
        let single = schema?.singleChoice
        #expect(single?.property.name == "colour")
        #expect(single?.choices.map(\.value) == ["red", "green"])
    }

    /// Two things asked for cannot be answered by one click, so the form stays a form.
    @Test func twoPropertiesKeepTheirForm() {
        let schema = ElicitationSchema(wire: .object([
            "properties": ["colour": ["type": "string", "enum": ["red"]],
                           "size": ["type": "string", "enum": ["big"]]],
            "propertyOrder": ["colour", "size"],
        ]))
        #expect(schema?.properties.count == 2)
        #expect(schema?.singleChoice == nil)
    }

    /// Free text has nothing to make a button out of.
    @Test func freeTextIsNotOneClick() {
        let schema = ElicitationSchema(wire: .object([
            "properties": ["name": ["type": "string"]],
        ]))
        #expect(schema?.singleChoice == nil)
    }

    @Test func aNumberIsNotOneClick() {
        let schema = ElicitationSchema(wire: .object([
            "properties": ["count": ["type": "integer"]],
        ]))
        #expect(schema?.singleChoice == nil)
    }

    /// Picking several cannot be one click by definition.
    @Test func aMultiSelectIsNotOneClick() {
        let schema = ElicitationSchema(wire: .object([
            "properties": ["tags": ["type": "array", "items": ["enum": ["a", "b"]]]],
        ]))
        #expect(schema?.singleChoice == nil)
    }
}
