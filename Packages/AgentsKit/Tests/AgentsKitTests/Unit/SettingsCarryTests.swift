import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a chat's settings become on another runtime (052, FR-015).
@Suite("Carrying settings across")
struct SettingsCarryTests {
    private func select(_ id: String, _ category: String, _ values: [String], current: String? = nil) -> ConfigOption {
        ConfigOption(id: id, name: id.capitalized, category: category,
                     kind: .select([ConfigChoiceGroup(name: nil, choices: values.map { ConfigChoice(value: .string($0), name: $0) })]),
                     currentValue: current.map(JSONValue.string))
    }

    private var claude: SettingsCarry.Side {
        SettingsCarry.Side(runtimeID: "claude",
                           options: [select("mode", "mode", ["plan", "default", "acceptEdits", "bypassPermissions"]),
                                     select("model", "model", ["opus", "sonnet"]),
                                     select("effort", "thought_level", ["low", "medium", "high"])],
                           values: ["mode": "acceptEdits", "model": "opus", "effort": "high"])
    }

    private var codex: SettingsCarry.Side {
        SettingsCarry.Side(runtimeID: "codex",
                           options: [select("mode", "mode", ["read-only", "auto", "agent"], current: "auto"),
                                     select("model", "model", ["gpt-5-codex", "gpt-5"], current: "gpt-5"),
                                     select("reasoning_effort", "thought_level", ["low", "medium", "high"], current: "medium")])
    }

    @Test func modeIsNeverLooser() throws {
        let plan = SettingsCarry.plan(from: claude, to: codex)
        #expect(plan.values["mode"] == "agent", "acceptEdits (2) → agent (2), not auto (3)")
        #expect(plan.rows.first { $0.optionID == "mode" }?.source == .closestNoLooser)
    }

    @Test func aModeWithNoPlaceGetsTheStrictest() {
        var from = claude
        from.values["mode"] = "somethingNew"
        #expect(SettingsCarry.plan(from: from, to: codex).values["mode"] == "read-only")
    }

    @Test func aLevelDecidesTheModelAndEffort() {
        let level = Level(name: "Strongest", cells: ["claude": Cell(model: "opus", effort: "high"),
                                                      "codex": Cell(model: "gpt-5-codex", effort: "high")])
        let plan = SettingsCarry.plan(from: claude, to: codex, levels: [level])
        #expect(plan.values["model"] == "gpt-5-codex")
        #expect(plan.values["reasoning_effort"] == "high")
        #expect(plan.rows.first { $0.optionID == "model" }?.source == .level("Strongest"))
    }

    @Test func withoutALevelThePoolEntryThenTheRememberedThenTheDefault() {
        #expect(SettingsCarry.plan(from: claude, to: codex, entryModel: "gpt-5").values["model"] == "gpt-5")
        #expect(SettingsCarry.plan(from: claude, to: codex, remembered: "gpt-5-codex").values["model"] == "gpt-5-codex")
        let plain = SettingsCarry.plan(from: claude, to: codex)
        #expect(plain.values["model"] == nil)
        #expect(plain.rows.first { $0.optionID == "model" }?.source == .runtimeDefault)
    }

    @Test func aModelIsNeverMatchedByName() {
        let same = SettingsCarry.Side(runtimeID: "copilot", options: [select("model", "model", ["opus", "gpt-5"])])
        #expect(SettingsCarry.plan(from: claude, to: same).values["model"] == nil)
    }

    @Test func effortCarriesWhenTheSameValueIsOffered() {
        #expect(SettingsCarry.plan(from: claude, to: codex).values["reasoning_effort"] == "high")
    }

    @Test func whatDoesNotCarryIsListed() {
        let plan = SettingsCarry.plan(from: claude, to: codex, extraArguments: ["--verbose"], alwaysAllowCount: 2,
                                      queuedCommands: ["/compact"])
        #expect(plan.dropped == [.extraArguments(["--verbose"]), .alwaysAllow(count: 2), .queuedSlashCommand("/compact")])
    }
}

/// US6 of 052: the grid, as a switch reads it and as the person edits it.
@Suite("Matching models")
struct MatchingModelsTests {
    private func side(_ runtimeID: String, models: [String], current: String? = nil) -> SettingsCarry.Side {
        let option = ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                                  currentValue: current.map(JSONValue.string),
                                  options: models.map { ConfigChoice(value: .string($0), name: $0) })
        return .init(runtimeID: runtimeID, options: [option], values: current.map { ["model": .string($0)] } ?? [:])
    }

    @Test func aCellWhoseModelIsGoneIsTreatedAsEmpty() {
        let level = Level(name: "Strongest", cells: ["claude": Cell(model: "opus"), "codex": Cell(model: "gpt-4")])
        let plan = SettingsCarry.plan(from: side("claude", models: ["opus"], current: "opus"),
                                      to: side("codex", models: ["gpt-5", "gpt-5-codex"]),
                                      levels: [level], entryModel: "gpt-5-codex")
        #expect(plan.values["model"] == .string("gpt-5-codex"))
        #expect(plan.rows.first?.source == .poolEntry)
        #expect(PoolSettings.isGone(Cell(model: "gpt-4"), offered: side("codex", models: ["gpt-5"]).options))
        #expect(!PoolSettings.isGone(Cell(model: "gpt-5"), offered: side("codex", models: ["gpt-5"]).options))
    }

    @Test func noLevelGivesTheFallbacks() {
        let plan = SettingsCarry.plan(from: side("claude", models: ["haiku"], current: "haiku"),
                                      to: side("codex", models: ["gpt-5"]),
                                      levels: [Level(name: "Strongest", cells: ["claude": Cell(model: "opus")])])
        #expect(plan.rows.first?.source == .runtimeDefault)
    }

    @Test func placingAModelMovesItOutOfItsOtherLevel() throws {
        var pool = PoolSettings(isOn: true, entries: [])
        let (withFirst, first) = pool.addingLevel(named: "Strongest")
        let (withBoth, second) = withFirst.addingLevel(named: "Everyday")
        pool = withBoth.placing(Cell(model: "opus"), for: "claude", in: first)
        pool = pool.placing(Cell(model: "opus"), for: "claude", in: second)
        #expect(pool.levels[0].cells["claude"] == nil)
        #expect(pool.levels[1].cells["claude"]?.model == "opus")
        try pool.validate()
    }

    @Test func rememberGoesInTheLevelThatHoldsTheChatsModelOrANewOne() throws {
        let (start, strongest) = PoolSettings(isOn: true, entries: []).addingLevel(named: "Strongest")
        let pool = start.placing(Cell(model: "opus"), for: "claude", in: strongest)
        let kept = pool.remembering(from: ("claude", Cell(model: "opus")), to: ("codex", Cell(model: "gpt-5-codex")))
        #expect(kept.levels.count == 1)
        #expect(kept.levels[0].cells["codex"]?.model == "gpt-5-codex")

        let fresh = pool.remembering(from: ("claude", Cell(model: "haiku")), to: ("codex", Cell(model: "gpt-5")),
                                     newLevelName: "Quick")
        #expect(fresh.levels.map(\.name) == ["Strongest", "Quick"])
        #expect(fresh.levels[1].cells == ["claude": Cell(model: "haiku"), "codex": Cell(model: "gpt-5")])
        try fresh.validate()
    }
}
