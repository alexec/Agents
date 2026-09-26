import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a pool must be before it is kept (052, FR-001a, FR-032).
@Suite("A pool's settings")
struct PoolSettingsTests {
    private let openAI = CredentialKind.openAIAPIKey.rawValue

    @Test func anAllowanceOnASignInIsFine() throws {
        let pool = PoolSettings(isOn: true, entries: [
            PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan")),
            PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan")),
        ])
        try pool.validate()
        #expect(pool.isEffective)
    }

    @Test(arguments: [
        Payment.freeTier(reset: .unknown),
        .freeCredit(amount: nil, expires: nil),
        .prepaid(amount: Cost(amount: 10, currency: "USD"), expires: nil),
    ])
    func aKeyWithAHardStopIsFine(payment: Payment) throws {
        try PoolSettings(entries: [PoolEntry(runtimeID: "codex", payment: payment, credentialRef: openAI)]).validate()
    }

    @Test func aKeyIsNeverAnAllowance() {
        let pool = PoolSettings(entries: [PoolEntry(runtimeID: "codex", payment: .allowance(label: nil), credentialRef: openAI)])
        #expect(throws: PoolSettings.Invalid.keyAsAnAllowance(runtimeID: "codex")) { try pool.validate() }
    }

    @Test func aSubscriptionTokenCanBeAnAllowance() throws {
        try PoolSettings(entries: [PoolEntry(runtimeID: "claude", payment: .allowance(label: nil),
                                             credentialRef: CredentialKind.oauthToken.rawValue)]).validate()
    }

    @Test func geminiIsNeverAnAllowance() {
        let pool = PoolSettings(entries: [PoolEntry(runtimeID: "gemini", payment: .allowance(label: nil))])
        #expect(throws: PoolSettings.Invalid.keyAsAnAllowance(runtimeID: "gemini")) { try pool.validate() }
    }

    @Test func creditMustBeSomething() {
        let pool = PoolSettings(entries: [PoolEntry(runtimeID: "codex", payment: .prepaid(amount: Cost(amount: 0, currency: "USD"), expires: nil),
                                                    credentialRef: openAI)])
        #expect(throws: PoolSettings.Invalid.amountNotPositive(runtimeID: "codex")) { try pool.validate() }
    }

    @Test func aModelIsInOneLevelPerRuntime() {
        let opus = Cell(model: "opus")
        let pool = PoolSettings(levels: [Level(name: "Strongest", cells: ["claude": opus]),
                                         Level(name: "Everyday", cells: ["claude": opus])])
        #expect(throws: PoolSettings.Invalid.modelInTwoLevels(runtimeID: "claude", first: "Strongest", second: "Everyday")) {
            try pool.validate()
        }
        #expect(PoolSettings.Invalid.modelInTwoLevels(runtimeID: "claude", first: "Strongest", second: "Everyday")
            .sentence.contains("Claude"))
    }

    @Test func theSameModelNameOnTwoRuntimesIsFine() throws {
        let cell = Cell(model: "opus")
        try PoolSettings(levels: [Level(name: "Strongest", cells: ["claude": cell, "copilot": cell])]).validate()
    }

    @Test func nothingMovesWithFewerThanTwo() {
        #expect(!PoolSettings(isOn: true, entries: [PoolEntry(runtimeID: "claude", payment: .allowance(label: nil))]).isEffective)
        #expect(!PoolSettings(isOn: false, entries: [PoolEntry(runtimeID: "claude", payment: .allowance(label: nil)),
                                                    PoolEntry(runtimeID: "codex", payment: .allowance(label: nil))]).isEffective)
    }

    @Test func itRoundTripsAndIgnoresWhatItDoesNotKnow() throws {
        let pool = PoolSettings(isOn: true, entries: [PoolEntry(runtimeID: "gemini", payment: .freeTier(reset: .gemini),
                                                                credentialRef: CredentialKind.geminiAPIKey.rawValue)],
                                levels: [Level(name: "Everyday", cells: ["gemini": Cell(model: "gemini-2.5-pro")])])
        let data = try JSONEncoder().encode(pool)
        #expect(try JSONDecoder().decode(PoolSettings.self, from: data) == pool)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["somethingNew"] = 1
        let widened = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(PoolSettings.self, from: widened) == pool)
    }
}
