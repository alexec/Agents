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

    @Test func aSettingHasOneFixedScope() {
        #expect(UserScopeWords.yoursOnEveryMachine == "Yours, on every machine")
        #expect(UserScopeWords.thisMacOnly == "This Mac's")
    }

    @Test func theAgentsEditorsSayWhenTheyLastSynced() {
        #expect(UserScopeWords.agentConfigurationUpdated(nil) == "Waiting for the first sync")
        #expect(UserScopeWords.agentConfigurationUpdated("not a date") == "Waiting for the first sync")
        #expect(UserScopeWords.agentConfigurationUpdated("2026-10-27T15:00:00Z").hasPrefix("Last synced "))
    }

    @Test func aPersonSettingCanBeKept() throws {
        let settings = try JSONValue.parse(Data(#"{"costLimits":{"dailyTokens":5}}"#.utf8)).decode(DaemonAPI.UserSettings.self)
        #expect(settings[.costLimits] != nil)
        #expect(settings[.mcpServers] == nil)
    }
}
