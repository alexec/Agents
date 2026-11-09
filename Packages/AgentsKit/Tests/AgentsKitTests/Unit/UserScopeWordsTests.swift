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

    /// #4167: a secret's description under its name, the same as `about` in userScope.ts; an
    /// empty field sends none.
    @Test func aSecretsRowSaysWhatItIsFor() {
        #expect(UserScopeWords.about(nil) == "No description")
        #expect(UserScopeWords.about("  ") == "No description")
        #expect(UserScopeWords.about(" A token for alexec/Agents. ") == "A token for alexec/Agents.")
        #expect(UserScopeWords.description(" \n ") == nil)
        #expect(UserScopeWords.description(" The shop. ") == "The shop.")
        let answer = ElicitationRequest.secretAnswer("v", sessionOnly: false, description: "The shop.")
        #expect(answer[ElicitationRequest.descriptionField] == .string("The shop."))
    }

    /// #3531: a card is one JSON value of its parts, the same as `cardValue` in userScope.ts,
    /// which agentsd's fill_secret reads a part at a time.
    @Test func aCardIsOneValueOfItsParts() {
        let card = CardSecret(number: "4242 4242 4242 4242", expiry: "9/2031", cvc: "737", name: " Sam Lee ", zip: "94110")
        #expect(card.problem == nil)
        #expect(card.value == #"{"cvc":"737","expiry":"09/31","name":"Sam Lee","number":"4242424242424242","zip":"94110"}"#)
        #expect(CardSecret(number: "4242", expiry: "0931", cvc: "737", name: "S", zip: "1").expiry == "09/31")
        #expect(CardSecret(number: "4242424242424241", expiry: "09/31", cvc: "737", name: "S", zip: "1").problem == "The card number is not right.")
        #expect(CardSecret(number: "4242424242424242", expiry: "13/31", cvc: "737", name: "S", zip: "1").problem == "Write the expiry as MM/YY.")
        #expect(CardSecret(number: "4242424242424242", expiry: "09/31", cvc: "73", name: "S", zip: "1").problem == "The CVC is 3 or 4 digits.")
        #expect(CardSecret(number: "4242424242424242", expiry: "09/31", cvc: "737", name: "", zip: "1").problem == "Write the name on the card.")
        var row = DaemonAPI.UserSecretRow(name: "SHOP_CARD", updated: "", machines: [])
        #expect(!row.isCard)
        row.kind = CardSecret.kind
        #expect(row.isCard)
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

    @Test func theAgentsEditorsSayWhatGoesToTheOtherMachines() {
        #expect(UserScopeWords.agentConfigurationFollows.hasPrefix("Your other machines get this Mac's instructions"))
        #expect(UserScopeWords.agentConfigurationFollows.hasSuffix("Workflows, plugins and a skill's other files stay on this Mac."))
    }

    @Test func aPersonSettingCanBeKept() throws {
        let settings = try JSONValue.parse(Data(#"{"costLimits":{"dailyTokens":5}}"#.utf8)).decode(DaemonAPI.UserSettings.self)
        #expect(settings[.costLimits] != nil)
        #expect(settings[.mcpServers] == nil)
    }
}
