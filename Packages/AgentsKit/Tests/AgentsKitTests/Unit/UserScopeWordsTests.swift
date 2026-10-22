@testable import AgentsKitCore
import Foundation
import Testing

/// You ▸ On Every Machine (#1760): the same words as `Web/src/model/userScope.ts`.
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
        #expect(UserScopeWords.partState(settings[.costLimits], updated: nil) == "The same on every machine of yours.")
    }

    /// #2069: an edit in a followed pane goes to every machine, and the words say so.
    @Test func aFollowedPaneSaysAnEditGoesToEveryMachine() {
        #expect(UserScopeWords.partsFoot.contains("the change goes to every machine of yours"))
        #expect(!UserScopeWords.partsFoot.contains("not in its own pane"))
        #expect(UserScopeWords.followedNote(.costLimits) == "Cost limits: a change here goes to every machine of yours, not only to this Mac.")
        #expect(UserScopeWords.replaceTitle(.resources, machine: "This Mac") == "Use This Mac’s Resources?")
    }
}
