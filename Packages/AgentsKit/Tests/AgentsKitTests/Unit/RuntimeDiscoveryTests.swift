import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

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

    @Test func cursorIsFoundByItsOwnNameAndNotByTheOneItCallsItself() {
        // Cursor's documentation, and its own sign-in text, call the command `agent`.
        // On this Mac `agent` is Grok, so starting what Cursor says to start would run
        // the wrong runtime. The recipe names `cursor-agent` and nothing else.
        #expect(RuntimeCatalog.cursor.executable == "cursor-agent")
        #expect(RuntimeCatalog.cursor.arguments == ["acp"])
        #expect(discovery(["/opt/homebrew/bin/cursor-agent"]).locate(RuntimeCatalog.cursor).isAvailable)
        #expect(!discovery(["/opt/homebrew/bin/agent"]).locate(RuntimeCatalog.cursor).isAvailable)
    }

    @Test func everyBuiltInRuntimeIsReportedOneWayOrTheOther() {
        let statuses = discovery(["/opt/homebrew/bin/copilot"]).statuses()
        #expect(statuses.count == 4)
        #expect(statuses.filter { $0.availability.isAvailable }.map(\.id) == ["copilot"])
        #expect(statuses.allSatisfy { RuntimeCatalog.runtime(id: $0.id) != nil })
    }

    @Test func theSearchPathIncludesTheOnesAGUIAppWouldMiss() {
        // The whole point: an app launched from the Finder inherits
        // /usr/bin:/bin:/usr/sbin:/sbin, and not one of the four lives there.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbacks = LoginShellPath.fallbacks
        #expect(fallbacks.contains("/opt/homebrew/bin"))
        // Where Cursor installs itself, and where Grok keeps the `agent` that is not Cursor.
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

    @Test func aControlReadsAsItsChoiceAndNothingElse() {
        let model = option(id: "model", name: "Model", category: "model",
                           choices: [("gpt-5.6-terra", "GPT-5.6 Terra"), ("gpt-5.4", "GPT-5.4")])
        #expect(model.closedTitle(for: nil) == "GPT-5.6 Terra")
        #expect(model.closedTitle(for: .string("gpt-5.4")) == "GPT-5.4")

        let mode = option(id: "mode", name: "Mode", category: "mode",
                          choices: [("agent", "Agent"), ("plan", "Plan")])
        #expect(mode.closedTitle(for: .string("plan")) == "Plan")
    }

    @Test func aValueTheRuntimeNoLongerOffersFallsBackToTheOptionName() {
        let mode = option(id: "mode", name: "Mode", category: "mode", choices: [("agent", "Agent")])
        #expect(mode.closedTitle(for: .string("withdrawn")) == "Mode")
    }

    @Test func permissionSitsApartFromTheRest() {
        // What an agent is allowed to do is a different kind of thing from how well
        // it does it, so the row is split on this.
        #expect(option(id: "mode", name: "Mode", category: "mode", choices: [("a", "A")]).isAboutPermission)
        #expect(option(id: "allow_all", name: "Allow all", category: "permissions",
                       choices: [("on", "On")]).isAboutPermission)
        #expect(!option(id: "model", name: "Model", category: "model", choices: [("a", "A")]).isAboutPermission)
        #expect(!option(id: "effort", name: "Effort", category: "thought_level",
                        choices: [("a", "A")]).isAboutPermission)
        #expect(!option(id: "fast", name: "Fast", category: "model_config",
                        choices: [("a", "A")]).isAboutPermission)
        #expect(!option(id: "x", name: "New", category: "invented_next_year",
                        choices: [("a", "A")]).isAboutPermission)
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
