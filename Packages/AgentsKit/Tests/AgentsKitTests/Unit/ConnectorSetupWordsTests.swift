import Foundation
import Testing
@testable import AgentsKitCore

/// A folder's Connectors set-up as the host sends it, and its words (#1336).
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
        #expect(ConnectorSetupWords.connectedNote(setup) == "Your connection, for every folder \u{00B7} sees 3 repositories")
        #expect(ConnectorSetupWords.proof(tasks) == "Newest: #7 Fix the walk")
        #expect(ConnectorSetupWords.title(review) == "Skipped")
        #expect(ConnectorSetupWords.line(ci, folder: "walk", repository: setup.repository)
                .hasPrefix("GitHub refused"))
        #expect(ConnectorSetupWords.eventNouns(setup.events.names) == ["checks.*", "pr.*", "issue.*"])
        #expect(ConnectorSetupWords.folderLine(setup) == "GitHub Issues, This Mac")
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
        #expect(ConnectorSetupWords.line(slot, folder: "Blog", repository: nil)
                == "Blog has no GitHub or GitLab remote, so GitHub Issues can't be read for it.")
    }

    /// Connect Linear (#1343): the hand-back page's agents://oauth/callback, read for the host.
    @Test func theCallbackGivesTheCodeAndTheState() throws {
        let flow = UUID()
        let url = try #require(URL(string: "agents://oauth/callback?code=c1&state=s1"))
        let r = try #require(DaemonAPI.ConnectionSignInCompleteRequest(flowID: flow, callback: url))
        #expect(r == .init(flowID: flow, state: "s1", code: "c1"))
        let denied = try #require(URL(string: "agents://oauth/callback?error=access_denied&state=s1"))
        #expect(DaemonAPI.ConnectionSignInCompleteRequest(flowID: flow, callback: denied)?.error == "access_denied")
        for other in ["agents://oauth/callback?code=c1", "https://oauth.agentloops.dev/oauth/callback?code=c1&state=s1",
                      "agents://other/callback?code=c1&state=s1"] {
            #expect(DaemonAPI.ConnectionSignInCompleteRequest(flowID: flow, callback: try #require(URL(string: other))) == nil)
        }
    }

    @Test func linearWords() {
        let c = DaemonAPI.Connection(provider: .linear, login: "Alex", connectedAt: Date(), workspace: "Loops")
        #expect(ConnectorSetupWords.connectionTitle(c) == "Linear \u{00B7} Alex")
        #expect(ConnectorSetupWords.connectionNote(c) == "Loops \u{00B7} OAuth \u{00B7} renews by itself")
    }

    /// Connect GitLab (#1630): a token's row says its GitLab and when it ends, as the web page's.
    @Test func gitlabWords() throws {
        let now = try Date("2026-10-20T00:00:00Z", strategy: .iso8601)
        let end = try Date("2027-10-19T00:00:00Z", strategy: .iso8601)
        let c = DaemonAPI.Connection(provider: .gitlab, login: "agentstest", connectedAt: now,
                                     workspace: "gitlab.example.com", expiresAt: end)
        #expect(ConnectorSetupWords.connectionTitle(c) == "GitLab \u{00B7} agentstest")
        #expect(ConnectorSetupWords.connectionNote(c, now: now) == "gitlab.example.com \u{00B7} Access token \u{00B7} ends 18 Oct 2027")
        var ended = c
        ended.state = .signInAgain
        #expect(ConnectorSetupWords.connectionNote(ended) == "The access token ended: connect again with a new one")
        #expect(ConnectorSetupWords.GitLab.newTokenURL("")
                == "https://gitlab.com/-/user_settings/personal_access_tokens?name=Agents&scopes=api")
        #expect(ConnectorSetupWords.GitLab.newTokenURL("gitlab.example.com/api/v4/")
                == "https://gitlab.example.com/-/user_settings/personal_access_tokens?name=Agents&scopes=api")
    }

    /// Connect Again\u{2026} on an ended GitLab connection opens the way it was made (#1865), as the
    /// web page's.
    @Test func gitlabConnectsAgainTheWayItWasMade() {
        let token = DaemonAPI.Connection(provider: .gitlab, state: .signInAgain, connectedAt: Date(),
                                         workspace: "gitlab.example.com", expiresAt: Date())
        let selfManaged = ConnectorSetupWords.GitLab.again(token)
        #expect(selfManaged.withToken && selfManaged.address == "https://gitlab.example.com")
        var com = token
        com.workspace = nil
        let comToken = ConnectorSetupWords.GitLab.again(com)
        #expect(comToken.withToken && comToken.address == "https://gitlab.com")
        com.expiresAt = nil
        let signIn = ConnectorSetupWords.GitLab.again(com)
        #expect(!signIn.withToken && signIn.address.isEmpty)
    }

    /// Connect Email (#1780): the row says the IMAP server and the app password, and no end.
    @Test func emailWords() {
        let c = DaemonAPI.Connection(provider: .email, login: "agents@example.com", connectedAt: Date(),
                                     workspace: "imap.fastmail.com")
        #expect(ConnectorSetupWords.connectionTitle(c) == "Email \u{00B7} agents@example.com")
        #expect(ConnectorSetupWords.connectionNote(c) == "imap.fastmail.com \u{00B7} App password")
        #expect(ConnectorSetupWords.letters(.email) == "EM")
        #expect(ConnectorSetupWords.Email.sheetFoot.contains("app password") && !ConnectorSetupWords.Email.sheetFoot.contains("token"))
        #expect(ConnectorSetupWords.noConnections.hasSuffix("and Email for the mail they wait for."))
    }

    /// Connect your tools with GitLab (#1632): the set-up's words follow its forge.
    @Test func gitlabSetUpWords() {
        let setup = DaemonAPI.ConnectorSetup(folder: "/p", repository: "group/app", forge: .gitlab, site: "gitlab.example.com",
                                             repositoryURL: "https://gitlab.example.com/group/app", slots: [],
                                             events: .init(state: .off), done: 1)
        #expect(ConnectorSetupWords.intro(folder: "App", repository: setup.repository, site: setup.siteOrGitHub)
                == "What agents in App can reach. Repository gitlab.example.com/group/app, from its git remote.")
        #expect(ConnectorSetupWords.connectButton(setup.forgeOrGitHub) == "Connect GitLab\u{2026}")
        #expect(ConnectorSetupWords.grantButton(setup) == "Open on gitlab.example.com")
        #expect(ConnectorSetupWords.grantURL(setup) == "https://gitlab.example.com/group/app")
        let ci = DaemonAPI.ConnectorSlot(slot: .ci, choice: "GitLab pipelines", state: .read)
        #expect(ConnectorSetupWords.line(ci, folder: "App", repository: "group/app", forge: .gitlab) == "No pipelines yet in group/app.")
        #expect(ConnectorSetupWords.eventsLead(setup.events, forge: .gitlab) == "Off. They go on once a slot has read from GitLab.")
        var github = setup
        github.forge = nil
        #expect(github.forgeOrGitHub == .github)
    }

    /// Disconnect names only the folders on that connection's forge (#1868), GitLab's too.
    @Test func disconnectNamesOnlyTheFoldersOnItsForge() {
        let read: [DaemonAPI.ConnectorSlot] = [.init(slot: .tasks, choice: "Issues", state: .read),
                                               .init(slot: .ci, choice: "CI", state: .read),
                                               .init(slot: .workspace, choice: "This Mac", state: .read)]
        let hub = DaemonAPI.ConnectorSetup(folder: "/hub", repository: "me/hub", slots: read, events: .init(state: .off), done: 3)
        let lab = DaemonAPI.ConnectorSetup(folder: "/lab", repository: "me/lab", forge: .gitlab, slots: read,
                                           events: .init(state: .off), done: 3)
        let folders = [(name: "Hub", setup: hub), (name: "Lab", setup: lab)]
        #expect(ConnectorSetupWords.disconnectMessage(.github, folders: folders)
                == "Hub loses Tasks, CI. " + ConnectorSetupWords.disconnectNote)
        #expect(ConnectorSetupWords.disconnectMessage(.gitlab, folders: folders)
                == "Lab loses Tasks, CI. " + ConnectorSetupWords.GitLab.disconnectNote)
        #expect(ConnectorSetupWords.GitLab.disconnectNote.contains("Every folder's GitLab slots wait for a connection again."))
        #expect(ConnectorSetupWords.disconnectMessage(.linear, folders: folders)
                == ConnectorSetupWords.disconnectNote(.linear))
    }
}
