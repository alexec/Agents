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

    /// The Docs slot (#3248): this folder's newest doc as its proof, its docs connectors under
    /// it, and never a slot a project sets or one that a forge's disconnect takes.
    @Test func theDocsSlot() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let json = """
        {"slot":"docs","choice":"This folder and Notion","state":"read","servers":["notion"],
         "proof":{"title":"specs/3248-docs/spec.md","at":\(now.addingTimeInterval(-7200).timeIntervalSinceReferenceDate)}}
        """
        let docs = try JSONDecoder().decode(DaemonAPI.ConnectorSlot.self, from: Data(json.utf8))
        #expect(docs.slot == .docs && !docs.slot.isProjects)
        #expect(ConnectorSetupWords.heading(.docs) == "Docs")
        #expect(ConnectorSetupWords.title(docs) == "This folder and Notion")
        #expect(ConnectorSetupWords.proof(docs, now: now) == "Newest: specs/3248-docs/spec.md 2 hours ago")
        #expect(ConnectorSetupWords.Docs.servers(docs.servers ?? []) == "Connectors: notion")
        #expect(ConnectorSetupWords.Docs.servers([]) == nil)
        // Each docs connector's one real search, through its map (#3307).
        let found = try JSONDecoder().decode([DaemonAPI.DocsServer].self, from: Data("""
        [{"name":"kb","state":"read","proof":{"title":"Design of the docs slot","url":"https://kb.example.com/P1"}},
         {"name":"notion","state":"noMap"},{"name":"wiki","state":"failed","message":"It wants a sign-in first."},
         {"name":"drive","state":"read"},{"name":"new","state":"notRead"}]
        """.utf8))
        #expect(found.map(ConnectorSetupWords.Docs.serverLine) == [
            "kb: found \u{201C}Design of the docs slot\u{201D}",
            "notion: no map of its search yet. Ask an agent to map it (the map-a-docs-server skill).",
            "wiki: It wants a sign-in first.",
            "drive: searched, and found no doc.",
            "new: searching\u{2026}",
        ])
        let empty = DaemonAPI.ConnectorSlot(slot: .docs, choice: "This folder", state: .read)
        #expect(ConnectorSetupWords.line(empty, folder: "walk", repository: nil) == ConnectorSetupWords.Docs.none)
        let skipped = DaemonAPI.ConnectorSlot(slot: .docs, choice: "This folder", state: .skipped)
        #expect(ConnectorSetupWords.line(skipped, folder: "walk", repository: nil).hasPrefix("Agents won't look for docs"))

        var setup = try JSONDecoder().decode(Setup.self, from: Data(Self.answer.utf8))
        setup.slots.insert(docs, at: 3)
        #expect(ConnectorSetupWords.disconnectMessage(.github, folders: [("walk", setup)]).hasPrefix("walk loses Tasks."))
    }

    /// The Messaging slot (#1787): None until a chat or email connector is there, then each
    /// connector's one read and its events.
    @Test func theMessagingSlot() throws {
        let slot = try JSONDecoder().decode(DaemonAPI.ConnectorSlot.self, from: Data("""
        {"slot":"messaging","choice":"Slack and Email","state":"read","servers":["slack","gmail"],
         "messagingServers":[{"name":"slack","word":"Slack","state":"read","proof":{"title":"3 channels"},
          "events":["slack.message"]},{"name":"gmail","word":"Email","state":"failed","message":"It wants a sign-in first."},
          {"name":"Slack","word":"Slack","state":"notRead"}]}
        """.utf8))
        #expect(!slot.slot.isProjects && ConnectorSetupWords.heading(.messaging) == "Messaging")
        #expect(ConnectorSetupWords.title(slot) == "Slack and Email")
        #expect((slot.messagingServers ?? []).map(ConnectorSetupWords.Messaging.serverLine) == [
            "Slack (slack): read 3 channels; events slack.message",
            "Email (gmail): It wants a sign-in first.",
            "Slack: reading\u{2026}",
        ])
        let none = DaemonAPI.ConnectorSlot(slot: .messaging, choice: "None", state: .skipped)
        #expect(ConnectorSetupWords.title(none) == "None")
        #expect(ConnectorSetupWords.line(none, folder: "walk", repository: nil).hasSuffix("to reach you there too."))
        let skipped = DaemonAPI.ConnectorSlot(slot: .messaging, choice: "Slack", state: .skipped, servers: ["slack"])
        #expect(ConnectorSetupWords.line(skipped, folder: "walk", repository: nil).hasSuffix("their events with them."))
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
                == "Blog has no GitHub, GitLab, Forgejo or Bitbucket remote, so GitHub Issues can't be read for it.")
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

    /// Connect Forgejo (#3752): a token's row says its Forgejo, Make a Token opens its
    /// applications page, and a Forgejo folder says pull requests and checks, as the web page's.
    @Test func forgejoWords() {
        let c = DaemonAPI.Connection(provider: .forgejo, login: "agentstest", connectedAt: Date(), workspace: "codeberg.org")
        #expect(ConnectorSetupWords.connectionTitle(c) == "Forgejo \u{00B7} agentstest")
        #expect(ConnectorSetupWords.connectionNote(c) == "codeberg.org \u{00B7} Access token")
        #expect(ConnectorSetupWords.Forgejo.again(c) == "https://codeberg.org")
        #expect(ConnectorSetupWords.Forgejo.newTokenURL("") == "https://codeberg.org/user/settings/applications")
        #expect(ConnectorSetupWords.Forgejo.newTokenURL("git.example.com/api/v1/") == "https://git.example.com/user/settings/applications")
        #expect(ConnectorSetupWords.connectTitle(.forgejo) == "Connect Forgejo once: issues, pull requests and checks.")
        #expect(ConnectorSetupWords.connectButton(.forgejo) == "Connect Forgejo\u{2026}")
        let ci = DaemonAPI.ConnectorSlot(slot: .ci, choice: "Forgejo checks", state: .read)
        #expect(ConnectorSetupWords.line(ci, folder: "App", repository: "team/app", forge: .forgejo)
                == "No checks yet on team/app's default branch.")
    }

    /// Connect Bitbucket (#3785): a token's row says bitbucket.org, and a Bitbucket folder says
    /// pull requests and checks and opens the repository on a refusal, as the web page's.
    @Test func bitbucketWords() {
        let c = DaemonAPI.Connection(provider: .bitbucket, login: "agentstest", connectedAt: Date(), workspace: "bitbucket.org")
        #expect(ConnectorSetupWords.connectionTitle(c) == "Bitbucket \u{00B7} agentstest")
        #expect(ConnectorSetupWords.connectionNote(c) == "bitbucket.org \u{00B7} Token")
        #expect(ConnectorSetupWords.letters(.bitbucket) == "BB")
        #expect(ConnectorSetupWords.connectTitle(.bitbucket) == "Connect Bitbucket once: issues, pull requests and checks.")
        #expect(ConnectorSetupWords.connectButton(.bitbucket) == "Connect Bitbucket\u{2026}")
        let ci = DaemonAPI.ConnectorSlot(slot: .ci, choice: "Bitbucket checks", state: .read)
        #expect(ConnectorSetupWords.line(ci, folder: "App", repository: "team/app", forge: .bitbucket)
                == "No checks yet on team/app's default branch.")
        #expect(ConnectorSetupWords.disconnectNote(.bitbucket).hasPrefix("Disconnect deletes the machine's token. Every folder's Bitbucket slots"))
    }

    /// A connection that ended turns the Connectors rows red (#3407): a refused renewal, or a
    /// token whose end has passed. The same as the web page's `endedConnections`.
    @Test func aConnectionEndsWhenRefusedOrPastItsEnd() {
        let now = Date()
        let fine = DaemonAPI.Connection(provider: .github, connectedAt: now)
        let refused = DaemonAPI.Connection(provider: .github, state: .signInAgain, connectedAt: now)
        let expired = DaemonAPI.Connection(provider: .gitlab, connectedAt: now, expiresAt: now.addingTimeInterval(-60))
        let later = DaemonAPI.Connection(provider: .gitlab, connectedAt: now, expiresAt: now.addingTimeInterval(60))
        #expect(!ConnectorSetupWords.hasEnded(fine, now: now) && !ConnectorSetupWords.hasEnded(later, now: now))
        #expect(ConnectorSetupWords.ended([fine, refused, later, expired], now: now).map(\.provider) == [.github, .gitlab])
        #expect(ConnectorSetupWords.endedLine([]) == nil)
        #expect(ConnectorSetupWords.endedLine([expired]) == "Your GitLab connection ended")
        #expect(ConnectorSetupWords.endedLine([refused, expired]) == "Your GitHub and GitLab connections ended")
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

    /// Connect Jira (#3304): the connection is Atlassian's, for Jira and Confluence; the sheet says
    /// Jira, waits on atlassian.com, and ends on the newest issue.
    @Test func jiraWords() {
        let now = Date()
        var c = DaemonAPI.Connection(provider: .atlassian, login: "Alex", connectedAt: now, workspace: "Acme",
                                     newest: .init(title: "ACME-7 Fix the walk", at: now.addingTimeInterval(-7200)))
        #expect(ConnectorSetupWords.connectionTitle(c) == "Atlassian \u{00B7} Alex")
        #expect(ConnectorSetupWords.connectionNote(c) == "Acme \u{00B7} OAuth \u{00B7} renews by itself")
        c.byToken = true
        #expect(ConnectorSetupWords.connectionNote(c) == "Acme \u{00B7} API token")
        #expect(ConnectorSetupWords.menuName(.atlassian) == "Jira and Confluence" && ConnectorSetupWords.menuName(.linear) == "Linear")
        #expect(ConnectorSetupWords.Jira.connected(c) == "Connected to Acme as Alex.")
        #expect(ConnectorSetupWords.Jira.proof(c, now: now) == "Newest issue: ACME-7 Fix the walk 2 hours ago")
        c.newest = nil
        #expect(ConnectorSetupWords.Jira.proof(c).hasPrefix("No issues read yet"))
        let flow = DaemonAPI.ConnectionSignIn(flowID: UUID(), provider: .atlassian, status: .waiting, grant: .authorizationCode,
                                              verificationURL: "https://auth.atlassian.com", expiresAt: now)
        #expect(ConnectorSetupWords.sheetStatus(flow) == ConnectorSetupWords.Jira.waiting)
        #expect(ConnectorSetupWords.continueButton(.atlassian) == "Continue on atlassian.com")
        #expect(ConnectorSetupWords.disconnectNote(.atlassian).contains("JIRA_API_TOKEN"))
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
