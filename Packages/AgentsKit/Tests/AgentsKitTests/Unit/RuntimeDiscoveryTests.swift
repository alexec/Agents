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
