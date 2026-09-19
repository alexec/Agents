import Foundation
import Testing
@testable import AgentsKit

@Suite("Runtime discovery", .timeLimit(.minutes(1)))
struct RuntimeDiscoveryTests {
    /// A PATH that exists only in the test.
    private func discovery(_ present: Set<String>, paths: [String] = ["/opt/homebrew/bin", "/usr/bin"]) -> RuntimeDiscovery {
        RuntimeDiscovery(searchPaths: paths, fileExists: { present.contains($0) })
    }

    @Test func findsARuntimeOnThePath() {
        let found = discovery(["/opt/homebrew/bin/copilot"]).locate(RuntimeCatalog.copilot)
        #expect(found.isAvailable)
        if case .available(let path, _) = found { #expect(path == "/opt/homebrew/bin/copilot") }
    }

    @Test func saysWhereItLookedWhenARuntimeIsMissing() {
        let missing = discovery([]).locate(RuntimeCatalog.grok)
        guard case .missing(let lookedIn) = missing else { Issue.record("not missing"); return }
        #expect(lookedIn == ["/opt/homebrew/bin", "/usr/bin"])
    }

    @Test func claudeIsFoundByItsAdapterRunner() {
        // There is no `claude` binary to find: the recipe runs an npm package through
        // the user's Node, so what has to exist is npx.
        #expect(RuntimeCatalog.claude.executable == "npx")
        #expect(RuntimeCatalog.claude.arguments == ["-y", "@agentclientprotocol/claude-agent-acp"])
        #expect(discovery(["/opt/homebrew/bin/npx"]).locate(RuntimeCatalog.claude).isAvailable)
        #expect(!discovery(["/opt/homebrew/bin/claude"]).locate(RuntimeCatalog.claude).isAvailable)
    }

    @Test func everyBuiltInRuntimeIsReportedOneWayOrTheOther() {
        let statuses = discovery(["/opt/homebrew/bin/copilot"]).statuses()
        #expect(statuses.count == 3)
        #expect(statuses.filter { $0.availability.isAvailable }.map(\.id) == ["copilot"])
        #expect(statuses.allSatisfy { RuntimeCatalog.runtime(id: $0.id) != nil })
    }

    @Test func theSearchPathIncludesTheOnesAGUIAppWouldMiss() {
        // The whole point: an app launched from the Finder inherits
        // /usr/bin:/bin:/usr/sbin:/sbin, and not one of the three lives there.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbacks = LoginShellPath.fallbacks
        #expect(fallbacks.contains("/opt/homebrew/bin"))
        #expect(fallbacks.contains("\(home)/.local/bin"))
        #expect(fallbacks.contains("\(home)/.grok/bin"))
    }

    @Test func theLoginShellPathIsReadAndKept() {
        let directories = LoginShellPath.directories()
        #expect(directories.contains("/usr/bin"))
        #expect(Set(directories).count == directories.count, "no duplicates from merging in the fallbacks")
        #expect(LoginShellPath.environment()["PATH"] == directories.joined(separator: ":"))
    }
}

@Suite("How an advertised option reads")
struct ConfigOptionReadingTests {
    private func option(id: String, name: String, category: String?, choices: [(String, String)]) -> ConfigOption {
        ConfigOption(id: id, name: name, category: category, type: "select",
                     currentValue: .string(choices[0].0),
                     options: choices.map { ConfigChoice(value: .string($0.0), name: $0.1) })
    }

    @Test func choicesThatNameThemselvesNeedNoLabel() {
        let model = option(id: "model", name: "Model", category: "model",
                           choices: [("gpt-5.6-terra", "GPT-5.6 Terra"), ("gpt-5.4", "GPT-5.4")])
        #expect(model.choicesNameThemselves)
        #expect(model.closedTitle(for: nil) == "GPT-5.6 Terra")

        let effort = option(id: "reasoning_effort", name: "Reasoning Effort", category: "thought_level",
                            choices: [("high", "High Effort"), ("xhigh", "Extra High Effort")])
        #expect(effort.closedTitle(for: .string("xhigh")) == "Extra High Effort")
    }

    @Test func choicesThatDoNotCarryTheLabelInTheClosedControl() {
        // "Agent" on its own is a word, not a setting.
        let mode = option(id: "mode", name: "Mode", category: "mode",
                          choices: [("agent", "Agent"), ("plan", "Plan")])
        #expect(!mode.choicesNameThemselves)
        #expect(mode.closedTitle(for: nil) == "Mode: Agent")
        #expect(mode.closedTitle(for: .string("plan")) == "Mode: Plan")

        let fast = option(id: "fast", name: "Fast", category: "model_config",
                          choices: [("off", "Off"), ("on", "On")])
        #expect(fast.closedTitle(for: .string("on")) == "Fast: On")
    }

    @Test func anUnfamiliarCategoryKeepsItsLabel() {
        // A wrong guess here is a control nobody can read, so anything new is labelled.
        let mystery = option(id: "x", name: "Something New", category: "invented_next_year",
                             choices: [("a", "A"), ("b", "B")])
        #expect(!mystery.choicesNameThemselves)
        #expect(mystery.closedTitle(for: nil) == "Something New: A")
    }

    @Test func aValueTheRuntimeNoLongerOffersFallsBackToTheOptionName() {
        let mode = option(id: "mode", name: "Mode", category: "mode",
                          choices: [("agent", "Agent")])
        #expect(mode.closedTitle(for: .string("withdrawn")) == "Mode")
    }

    @Test func theOptionsRowIsOrderedModeModelThoughtLevelThenTheRest() {
        let unsorted = [
            option(id: "fast", name: "Fast", category: "model_config", choices: [("a", "A")]),
            option(id: "effort", name: "Effort", category: "thought_level", choices: [("a", "A")]),
            option(id: "mode", name: "Mode", category: "mode", choices: [("a", "A")]),
            option(id: "model", name: "Model", category: "model", choices: [("a", "A")]),
        ]
        let sorted = unsorted.sorted { $0.categoryRank < $1.categoryRank }
        #expect(sorted.map(\.id) == ["mode", "model", "effort", "fast"])
    }
}

@Suite("How a row of options reads together")
struct ConfigOptionRowTests {
    private func option(id: String, name: String, category: String, choice: String) -> ConfigOption {
        ConfigOption(id: id, name: name, category: category, type: "select",
                     currentValue: .string("v"), options: [ConfigChoice(value: .string("v"), name: choice)])
    }

    @Test func aChoiceThatNamesNoSettingKeepsItsLabel() {
        // The Claude adapter calls both its model and its effort level "Default".
        let model = option(id: "model", name: "Model", category: "model", choice: "Default")
        #expect(model.closedTitle(for: nil) == "Model: Default")

        let effort = option(id: "effort", name: "Effort", category: "thought_level",
                            choice: "Default (recommended)")
        #expect(effort.closedTitle(for: nil) == "Effort: Default (recommended)")
    }

    @Test func aNameThatTurnsUpTwiceGetsItsLabelBack() {
        let options = [
            option(id: "model", name: "Model", category: "model", choice: "Sonnet"),
            option(id: "fallback", name: "Fallback", category: "model", choice: "Sonnet"),
        ]
        let titles = options.closedTitles(chosen: [:])
        #expect(titles["model"] == "Model: Sonnet")
        #expect(titles["fallback"] == "Fallback: Sonnet")
    }

    @Test func distinctChoicesStillNeedNoLabel() {
        let options = [
            option(id: "model", name: "Model", category: "model", choice: "GPT-5.6 Terra"),
            option(id: "effort", name: "Reasoning Effort", category: "thought_level", choice: "High Effort"),
            option(id: "mode", name: "Mode", category: "mode", choice: "Agent"),
        ]
        let titles = options.closedTitles(chosen: [:])
        #expect(titles["model"] == "GPT-5.6 Terra")
        #expect(titles["effort"] == "High Effort")
        #expect(titles["mode"] == "Mode: Agent")
    }
}
