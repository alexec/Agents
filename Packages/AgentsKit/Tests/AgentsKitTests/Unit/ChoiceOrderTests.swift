import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The order a menu's choices are drawn in (#436): Cursor sends its models jumbled.
@Suite("The order of a menu's choices")
struct ChoiceOrderTests {
    private func choices(_ names: [String]) -> [JSONValue] {
        names.map { ["value": .string($0.lowercased().replacingOccurrences(of: " ", with: "-")), "name": .string($0)] }
    }

    private func model(_ names: [String], category: String? = "model") -> ConfigOption? {
        var wire: [String: JSONValue] = ["id": "model", "name": "Model", "type": "select",
                                         "options": .array(choices(names))]
        if let category { wire["category"] = .string(category) }
        return ConfigOption(wire: .object(wire))
    }

    @Test func modelsAreGroupedByFamilyWithAutoFirst() {
        let option = model(["GPT-5", "Grok Code", "Claude Sonnet 4.5", "Composer 1", "Auto",
                            "Gemini 2.5 Pro", "o3", "Claude Opus 4.1"])
        #expect(option?.options?.map(\.name) == ["Auto", "Claude Sonnet 4.5", "Claude Opus 4.1",
                                                 "GPT-5", "o3", "Gemini 2.5 Pro", "Grok Code",
                                                 "Composer 1"])
    }

    @Test func numbersCompareAsNumbersNewestFirst() {
        let option = model(["gpt-5.9", "gpt-5.10", "gpt-5", "gpt-5.1-codex", "gpt-5.1"])
        #expect(option?.options?.map(\.name) == ["gpt-5.10", "gpt-5.9", "gpt-5.1", "gpt-5.1-codex", "gpt-5"])
    }

    @Test func atOneVersionTheMostCapableLeads() {
        let option = model(["Claude Haiku 4.5", "Claude Sonnet 4.5", "Claude Opus 4.5",
                            "claude-3-5-sonnet-20241022"])
        #expect(option?.options?.map(\.name) == ["Claude Opus 4.5", "Claude Sonnet 4.5",
                                                 "Claude Haiku 4.5", "claude-3-5-sonnet-20241022"])
    }

    @Test func defaultLeadsAsAutoDoes() {
        let option = model(["Opus", "Default (recommended)", "Haiku"])
        #expect(option?.options?.first?.name == "Default (recommended)")
    }

    @Test func orderedOptionsKeepTheRuntimesOrder() {
        let effort = ConfigOption(wire: ["id": "effort", "name": "Effort", "category": "thought_level",
                                         "type": "select",
                                         "options": .array(choices(["Low", "Medium", "High", "Extra high"]))])
        #expect(effort?.options?.map(\.name) == ["Low", "Medium", "High", "Extra high"])
        let mode = ConfigOption(wire: ["id": "mode", "name": "Mode", "category": "mode", "type": "select",
                                       "options": .array(choices(["Plan", "Default", "Accept edits"]))])
        #expect(mode?.options?.map(\.name) == ["Plan", "Default", "Accept edits"])
        // A short list with no category may be a scale; only a long one is sorted.
        #expect(model(["C", "A", "B"], category: nil)?.options?.map(\.name) == ["C", "A", "B"])
    }

    @Test func groupsStayPutAndSortWithin() {
        let option = ConfigOption(wire: ["id": "model", "name": "Model", "category": "model", "type": "select",
                                         "options": [
                                            ["group": "b", "name": "Other",
                                             "options": .array(choices(["Kimi K2", "DeepSeek V3"]))],
                                            ["group": "a", "name": "Anthropic",
                                             "options": .array(choices(["Claude Haiku 4.5", "Claude Opus 4.5"]))],
                                         ]])
        #expect(option?.groups.map(\.name) == ["Other", "Anthropic"])
        #expect(option?.options?.map(\.name) == ["DeepSeek V3", "Kimi K2", "Claude Opus 4.5", "Claude Haiku 4.5"])
    }

    @Test func theOrderIsStableAndSurvivesARecord() throws {
        let option = try #require(model(["Composer 1", "Auto", "GPT-5", "Claude Sonnet 4.5"]))
        let again = try JSONDecoder().decode(ConfigOption.self, from: JSONEncoder().encode(option))
        #expect(again.options == option.options)
        #expect(ChoiceOrder.sorted(option.options ?? []) == option.options)
    }

    @Test func theOlderStyleModelListIsSortedToo() {
        // Cursor advertises its models the older way, under `models`.
        let options = ACPSession.olderStyleOptions(in: [
            "models": ["currentModelId": "auto",
                       "availableModels": [["modelId": "gpt-5", "name": "GPT-5"],
                                           ["modelId": "sonnet-4.5", "name": "Claude Sonnet 4.5"],
                                           ["modelId": "auto", "name": "Auto"]]],
        ])
        #expect(options.first?.options?.map(\.name) == ["Auto", "Claude Sonnet 4.5", "GPT-5"])
    }
}
