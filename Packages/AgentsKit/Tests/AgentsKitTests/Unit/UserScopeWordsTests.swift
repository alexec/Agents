@testable import AgentsKitCore
import Foundation
import Testing

/// The user scope (#1760, #2157): the same words as `Web/src/model/userScope.ts`.
struct UserScopeWordsTests {
    @Test func aSecretsRowSaysWhereItIs() {
        let row = DaemonAPI.UserSecretRow(name: "A", updated: "", machines: ["mac", "box"],
                                          leftOn: [.init(host: "old", name: "Sam's box", at: "")])
        #expect(UserScopeWords.machines(row) == "On 2 machines")
        #expect(UserScopeWords.leftOn(row)?.hasPrefix("It was on Sam's box, which was removed") == true)
        #expect(UserScopeWords.secretsLeft(.init(host: "old", name: "Sam's box", secrets: ["A"]))
            == "Sam's box was removed with this secret on it: A. Change it where it was issued.")
    }

    @Test func aSecretsNameIsAnEnvironmentVariables() {
        #expect(UserScopeWords.isSecretName("GITHUB_TOKEN"))
        #expect(!UserScopeWords.isSecretName("github_token"))
        #expect(!UserScopeWords.isSecretName("../X"))
    }

    @Test func aPartFollowsWhenKept() throws {
        let settings = try JSONValue.parse(Data(#"{"costLimits":{"dailyTokens":5}}"#.utf8)).decode(DaemonAPI.UserSettings.self)
        #expect(settings[.costLimits] != nil)
        #expect(settings[.mcpServers] == nil)
        #expect(UserScopeWords.partState(settings[.costLimits], updated: nil) == "All your machines")
        #expect(UserScopeWords.partState(settings[.mcpServers], updated: nil) == "Each machine its own")
    }

    /// #2069, #2157: the line over a Mac pane says where an edit in it goes.
    @Test func thePanesScopeLineSaysWhereAnEditGoes() {
        #expect(UserScopeWords.scopeNote(.costLimits, follows: true)
            == "Cost limits: a change here goes to every machine of yours, and to each new one.")
        #expect(UserScopeWords.scopeNote(.costLimits, follows: false)
            == "Cost limits: turn it on to give every machine of yours what this Mac has.")
        #expect(UserScopeWords.stopTitle(.resources) == "Resources: each machine its own?")
        #expect(UserScopeWords.partsFoot.hasPrefix("Turn one on in its own pane on the Mac."))
    }

    /// #2390: turning a part on asks first, naming what is replaced and where.
    @Test func turningAPartOnSaysWhatItReplaces() {
        #expect(UserScopeWords.takeTitle(.mcpServers) == "MCP servers: the same on all your machines?")
        #expect(UserScopeWords.takeMessage(.mcpServers, machines: ["devbox", "Studio"])
            == "Replaces the MCP servers on devbox and Studio with this Mac’s, and gives each new machine of yours this Mac’s too. "
            + "Turning this off later does not bring the old ones back.")
        #expect(UserScopeWords.takeMessage(.costLimits, machines: []).hasPrefix(
            "Replaces the cost limits on every other machine of yours with this Mac’s,"))
        #expect(UserScopeWords.takeMessage(.resources, machines: ["a", "b", "c"]).contains("on a, b and c with this Mac’s"))
    }
}
