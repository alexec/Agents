import Foundation
import Testing
@testable import AgentsKitCore

/// A project's Connectors set-up as the host sends it, and its words (#1336).
@Suite("Connector set-up words")
struct ConnectorSetupWordsTests {
    typealias Setup = DaemonAPI.ConnectorSetup

    static let answer = """
    {"folder":"/tmp/walk","repository":"alexec/agents-walk","installed":false,"repositories":3,
     "installURL":"https://github.com/apps/agents-loops/installations/new",
     "connection":{"provider":"github","login":"alexec","state":"connected","connectedAt":782000000},
     "slots":[
      {"slot":"tasks","choice":"GitHub Issues","state":"read","proof":{"number":7,"title":"Fix the walk","url":"u"}},
      {"slot":"codeReview","choice":"GitHub pull requests","state":"skipped"},
      {"slot":"ci","choice":"GitHub Actions","state":"refused","message":"GitHub refused: Agents can't see Actions runs in alexec/agents-walk."},
      {"slot":"workspace","choice":"This Mac","state":"read"}],
     "events":{"state":"on","names":["checks.failed","pr.opened","pr.merged","issue.opened"],"server":"github",
               "workflows":[{"id":"babysit","name":"Babysit PRs"}]},
     "done":3}
    """

    @Test func theHostsAnswerReads() throws {
        let setup = try JSONDecoder().decode(Setup.self, from: Data(Self.answer.utf8))
        #expect(setup.done == 3 && setup.installed == false && setup.repositories == 3)
        #expect(setup.slot(.tasks)?.proof?.number == 7)
        let tasks = try #require(setup.slot(.tasks))
        let review = try #require(setup.slot(.codeReview))
        let ci = try #require(setup.slot(.ci))
        #expect(ConnectorSetupWords.setUpHeading(setup) == "Set up \u{00B7} 3 of 4")
        #expect(ConnectorSetupWords.connectedNote(setup) == "Your connection, for every project \u{00B7} sees 3 repositories")
        #expect(ConnectorSetupWords.proof(tasks) == "Newest: #7 Fix the walk")
        #expect(ConnectorSetupWords.title(review) == "Skipped")
        #expect(ConnectorSetupWords.line(ci, project: "walk", repository: setup.repository)
                .hasPrefix("GitHub refused"))
        #expect(ConnectorSetupWords.eventNouns(setup.events.names) == ["checks.*", "pr.*", "issue.*"])
        #expect(ConnectorSetupWords.projectLine(setup) == "GitHub Issues, This Mac")
    }

    @Test func aRunSaysWhenItRan() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let run = DaemonAPI.ConnectorProof(title: "CI on main", outcome: "passed", at: now.addingTimeInterval(-240))
        #expect(ConnectorSetupWords.proofText(run, now: now) == "CI on main, passed 4 min ago")
        #expect(ConnectorSetupWords.ago(now.addingTimeInterval(-7200), now: now) == "2 hours ago")
    }

    @Test func aTrackerWithNoGitHubRemote() {
        let slot = DaemonAPI.ConnectorSlot(slot: .tasks, choice: "GitHub Issues", state: .noRemote)
        #expect(ConnectorSetupWords.title(slot) == "Choose a tracker")
        #expect(ConnectorSetupWords.line(slot, project: "Blog", repository: nil)
                == "Blog has no GitHub remote, so GitHub Issues can't be read for it.")
    }
}
