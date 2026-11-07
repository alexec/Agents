import Foundation
import Testing
@testable import AgentsKitCore

/// The person's agents' bot as the host sends it, and its words (#3858).
@Suite("Agents' bot words")
struct AgentsBotWordsTests {
    typealias Words = ConnectorSetupWords.Bot

    @Test func theBotsLineSaysWhereItIsInstalled() throws {
        #expect(Words.note(DaemonAPI.ConnectionBot(made: false)) == Words.notMade)
        let json = """
        {"made":true,"name":"alexec-agents[bot]","slug":"alexec-agents","owner":"alexec",
         "installURL":"https://github.com/apps/alexec-agents/installations/new",
         "installations":[{"account":"alexec","all":false},{"account":"scratch-org","all":true}]}
        """
        let bot = try JSONDecoder().decode(DaemonAPI.ConnectionBot.self, from: Data(json.utf8))
        #expect(Words.note(bot) == "alexec-agents[bot], on alexec (chosen repositories), scratch-org (all repositories).")
        var none = bot
        none.installations = []
        #expect(Words.note(none).contains("not installed yet"))
        none.installations = nil
        #expect(Words.note(none).contains("could not be asked"))
    }

    /// Which of the person's machines hold the bot's key (#3950); the web page says the same.
    @Test func theBotsKeyLineSaysWhichMachinesHaveIt() throws {
        #expect(Words.keyOn(DaemonAPI.ConnectionBot(made: false)) == nil)
        #expect(Words.keyOn(DaemonAPI.ConnectionBot(made: true)) == "Its key is on this machine only.")
        let json = """
        {"made":true,"keyOn":[{"name":"mac-mini","here":true,"has":true},{"name":"devbox","has":true},
         {"name":"laptop","has":false}]}
        """
        var bot = try JSONDecoder().decode(DaemonAPI.ConnectionBot.self, from: Data(json.utf8))
        #expect(Words.keyOn(bot) == "Its key is on mac-mini (here) and devbox. laptop gets it when it is online.")
        bot.keyOn?.append(DaemonAPI.ConnectionBotMachine(name: "pi", has: false))
        #expect(Words.keyOn(bot) == "Its key is on mac-mini (here) and devbox. laptop and pi get it when they are online.")
    }

    /// The Mac opens the manifest page with the manifest in the fragment, never in the query.
    @Test func theFormAddressKeepsTheManifestInTheFragment() throws {
        let start = DaemonAPI.ConnectionBotStart(action: "https://github.com/settings/apps/new?state=ab12",
                                                 manifest: #"{"name":"alexec-agents","public":false}"#,
                                                 state: "ab12", expiresAt: Date())
        let url = try #require(start.formURL)
        #expect(url.host == "oauth.agentloops.dev" && url.path == "/oauth/github-app" && url.query == nil)
        let items = URLComponents(string: "x:?" + (url.fragment ?? ""))?.queryItems ?? []
        #expect(items.first { $0.name == "action" }?.value == start.action)
        #expect(items.first { $0.name == "manifest" }?.value == start.manifest)
    }

    @Test func theCallbackGivesTheCodeAndTheState() throws {
        let url = try #require(URL(string: "agents://oauth/callback?code=c0de&state=ab12"))
        let r = try #require(DaemonAPI.ConnectionBotCompleteRequest(callback: url))
        #expect(r.code == "c0de" && r.state == "ab12" && r.error == nil)
        #expect(DaemonAPI.ConnectionBotCompleteRequest(callback: try #require(URL(string: "https://x/oauth/callback?state=a"))) == nil)
    }
}
