#if canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
@testable import AgentsKitCore

/// Reveal and Copy (#5112, #5116): a client opens `user/sealedSecret`'s copy with its own key,
/// and nothing else does; a card shows its five parts; Settings ▸ You ▸ Accounts ▸ Details…
/// gives each field, Copy only for the plain ones that have a value.
struct SecretRevealTests {
    @Test func aClientOpensItsOwnCopyAndNoOtherKeyDoes() throws {
        let key = DeviceKey.ephemeral()
        let client = UUID()
        let ad = ClientSealing.userSecretAD(user: "ada", recipient: ClientSealing.clientRecipient(client), name: "GITLAB_TOKEN",
                                            version: 7, ask: true)
        let envelope = try Envelope.seal(Data("glpat-x9Qe".utf8), to: key.publicKey, info: ClientSealing.userSecretPurpose,
                                         authenticating: ad)
        let sealed = DaemonAPI.UserSealedSecret(name: "GITLAB_TOKEN", version: 7, sealed: envelope, needsApproval: true)
        #expect(try ClientSealing.open(sealed, user: "ada", with: key, client: client) == "glpat-x9Qe")
        // Another person, another client, or Ask before use changed by the control plane: it does not open.
        #expect(throws: SecretRevealWords.RevealFailure.self) { try ClientSealing.open(sealed, user: "kim", with: key, client: client) }
        #expect(throws: SecretRevealWords.RevealFailure.self) { try ClientSealing.open(sealed, user: "ada", with: key, client: UUID()) }
        var flipped = sealed
        flipped.needsApproval = nil
        #expect(throws: SecretRevealWords.RevealFailure.self) { try ClientSealing.open(flipped, user: "ada", with: key, client: client) }
        #expect(SecretRevealWords.failure(SecretRevealWords.RevealFailure()) == SecretRevealWords.didNotOpen)
        #expect(SecretRevealWords.failure(JSONRPCError(code: DaemonAPI.Failure.noClientCopy, message: "x")) == SecretRevealWords.noCopy)
    }

    @Test func aCardShowsItsFivePartsAndCopiesTheDigits() throws {
        let card = try #require(CardSecret.parse(CardSecret(number: "4242 4242 4242 4242", expiry: "9/28", cvc: "123",
                                                            name: "Ada Example", zip: "94110").value))
        #expect(card.shown.map(\.label) == ["Card number", "Expiry", "CVC", "Name on card", "Billing ZIP"])
        #expect(card.shown.first?.text == "4242 4242 4242 4242")
        #expect(card.value(of: .number) == "4242424242424242")
        #expect(card.value(of: .expiry) == "09/28")
        #expect(CardSecret.parse("ghp_notacard") == nil)
    }

    @Test func detailsGiveCopyOnlyForThePlainFieldsWithAValue() {
        let a = DaemonAPI.OutsideAccount(service: "gitlab.com", description: "Agents' GitLab, for forge tests.",
                                         address: "agentloops@example.com", plan: "Free", monthlyCostUsd: 0, secret: "GITLAB_TOKEN",
                                         twoFactor: "TOTP", issue: "#4303", tokenExpires: "2027-02-01",
                                         notes: "Password is in Secrets as GITLAB_PASSWORD.", username: "agentloops")
        let identity = AccountsWords.identity(a)
        #expect(identity.map(\.label) == ["Service", "Address", "User name", "Description", "Plan", "Two-factor"])
        #expect(identity.filter(\.copies).map(\.label) == ["Service", "Address", "User name"])
        #expect(identity.first { $0.label == "Plan" }?.text == "Free · $0 a month")
        #expect(AccountsWords.record(a).map(\.label) == ["Notes", "Issue", "Projects"])
        #expect(AccountsWords.record(a).last?.text == "All")
        let now = Date(timeIntervalSince1970: 1_762_992_000) // 2025-11-13
        #expect(AccountsWords.tokenExpiry(a, now: now) == "2027-02-01 (in 445 d)")
        #expect(AccountsWords.auditAccount(a) == .init(service: "gitlab.com", address: "agentloops@example.com"))
        // The user name goes through the sheet's fields and back.
        #expect(AccountsWords.account(AccountsWords.fields(a)).username == "agentloops")
    }

    @Test func anAccountNamesASecretInSecretsElsewhereOrNone() {
        let row = DaemonAPI.UserSecretRow(name: "GITLAB_TOKEN", updated: "", machines: [], leftOn: nil, version: 1, waiting: nil)
        #expect(AccountsWords.named("GITLAB_TOKEN", rows: [row]) == .secret(row))
        #expect(AccountsWords.named("1Password", rows: [row]) == .elsewhere("1Password"))
        #expect(AccountsWords.named("  ", rows: [row]) == AccountsWords.Named.none)
        #expect(AccountsWords.named(nil, rows: [row]) == AccountsWords.Named.none)
    }
}
#endif
