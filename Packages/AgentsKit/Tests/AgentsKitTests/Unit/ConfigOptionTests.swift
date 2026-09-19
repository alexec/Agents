import Foundation
import Testing
@testable import AgentsKit

/// The shapes a runtime may send for one setting.
///
/// The rule under test is the one the audit found broken: a shape we cannot read costs
/// that option, and never the session. None of the three runtimes groups its choices
/// today, which is exactly why this is tested rather than observed.
@Suite("Reading the options a runtime advertises")
struct ConfigOptionTests {
    @Test func aFlatListIsOneUnnamedGroup() {
        let option = ConfigOption(wire: ["id": "model", "name": "Model", "category": "model",
                                         "type": "select", "currentValue": "a",
                                         "options": [["value": "a", "name": "A"],
                                                     ["value": "b", "name": "B"]]])
        #expect(option?.isRenderable == true)
        #expect(option?.groups.count == 1)
        #expect(option?.groups.first?.name == nil)
        #expect(option?.options?.count == 2)
        #expect(option?.closedTitle(for: nil) == "A")
    }

    @Test func groupedChoicesKeepTheirHeadings() {
        let option = ConfigOption(wire: ["id": "model", "name": "Model", "type": "select",
                                         "currentValue": "haiku",
                                         "options": [
                                            ["group": "fast", "name": "Fast",
                                             "options": [["value": "haiku", "name": "Haiku"]]],
                                            ["group": "slow", "name": "Careful",
                                             "options": [["value": "opus", "name": "Opus"]]],
                                         ]])
        #expect(option?.groups.map(\.name) == ["Fast", "Careful"])
        #expect(option?.options?.map(\.name) == ["Haiku", "Opus"])
        #expect(option?.closedTitle(for: nil) == "Haiku")
        #expect(option?.isRenderable == true)
    }

    @Test func aSettingThatIsOnOrOffIsASwitch() {
        // What the Claude adapter sends once we say we take booleans.
        let option = ConfigOption(wire: ["id": "fast", "name": "Fast mode",
                                         "category": "model_config",
                                         "type": "boolean", "currentValue": true])
        #expect(option?.kind == .boolean)
        #expect(option?.isBoolean == true)
        #expect(option?.isRenderable == true)
        #expect(option?.options == nil)
    }

    @Test func aChoiceWithNoValueIsDroppedAndTheRestSurvive() {
        let option = ConfigOption(wire: ["id": "model", "name": "Model", "type": "select",
                                         "options": [["name": "No value here"],
                                                     ["value": "b", "name": "B"]]])
        #expect(option?.options?.map(\.name) == ["B"])
    }

    @Test func aTypeWeDoNotKnowIsSkippedRatherThanGuessedAt() {
        let option = ConfigOption(wire: ["id": "colour", "name": "Colour", "type": "hologram"])
        #expect(option?.kind == .unsupported("hologram"))
        #expect(option?.isRenderable == false)
    }

    @Test func oneUnreadableOptionCostsOnlyItself() {
        let list: JSONValue = [
            ["id": "model", "name": "Model", "type": "select",
             "options": [["value": "a", "name": "A"]]],
            ["name": "no id at all"],
            .string("not even an object"),
            ["id": "fast", "name": "Fast", "type": "boolean", "currentValue": false],
        ]
        let options = ConfigOption.list(in: list)
        #expect(options.map(\.id) == ["model", "fast"])
    }

    @Test func aListWeCannotReadAtAllCostsTheListAndNothingElse() {
        #expect(ConfigOption.list(in: .string("nonsense")).isEmpty)
        #expect(ConfigOption.list(in: nil).isEmpty)
        #expect(ConfigOption.list(in: .object([:])).isEmpty)
    }

    @Test func anEmptySelectIsNotAControl() {
        let option = ConfigOption(wire: ["id": "model", "name": "Model", "type": "select",
                                         "options": .array([])])
        #expect(option?.isRenderable == false)
    }

    @Test func groupsSurviveBeingWrittenDownAndReadBack() throws {
        let option = ConfigOption(wire: ["id": "model", "name": "Model", "type": "select",
                                         "options": [["group": "fast", "name": "Fast",
                                                      "options": [["value": "haiku", "name": "Haiku"]]]]])
        let data = try JSONEncoder().encode(option)
        let back = try JSONDecoder().decode(ConfigOption.self, from: data)
        #expect(back == option)
        #expect(back.groups.first?.name == "Fast")
    }

    @Test func aFlatListIsWrittenBackFlat() throws {
        // A record should stay the shape the runtime sent, not ours.
        let option = ConfigOption(id: "model", name: "Model", type: "select",
                                  options: [ConfigChoice(value: "a", name: "A")])
        let value = try JSONValue.encoding(option)
        #expect(value["options"]?.arrayValue?.first?["value"]?.stringValue == "a")
        #expect(value["type"]?.stringValue == "select")
    }
}
