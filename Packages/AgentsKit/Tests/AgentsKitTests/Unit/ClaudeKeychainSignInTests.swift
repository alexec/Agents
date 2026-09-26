import Foundation
import Testing
@testable import AgentsKit

/// Claude's sign-in on this Mac, as the relay reads it (056, research R5), against a fake
/// Keychain and a fake renewer: never the real item, and nothing here renews anything.
@Suite("Claude's sign-in on this Mac")
struct ClaudeKeychainSignInTests {
    final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        var item: Result<Data, MacSignInFailure>
        private(set) var reads = 0
        init(_ item: Result<Data, MacSignInFailure>) { self.item = item }
        func read() throws -> Data {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return try item.get()
        }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    static func item(access: String, expiresIn seconds: Double, from clock: Clock,
                     scopes: [String] = ["user:inference", "user:profile"]) -> Data {
        let expires = (clock.now.timeIntervalSince1970 + seconds) * 1000
        let object: [String: Any] = ["claudeAiOauth": ["accessToken": access, "refreshToken": "REFRESH-SECRET",
                                                       "expiresAt": expires, "scopes": scopes,
                                                       "subscriptionType": "max"]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func signIn(_ keychain: FakeKeychain, _ clock: Clock) -> ClaudeKeychainSignIn {
        ClaudeKeychainSignIn(reader: { try keychain.read() }, now: { clock.now })
    }

    @Test func aClaudeAccountWithInferenceIsOneTheRelayLends() throws {
        let clock = Clock()
        let keychain = FakeKeychain(.success(Self.item(access: "MAC-ACCESS", expiresIn: 3600, from: clock)))
        let source = signIn(keychain, clock)
        #expect(source.isSignedIn)
        #expect(try source.current() == MacSignInToken(access: "MAC-ACCESS"))
        #expect(try source.standIn() == "sk-ant-oat01-agents-relay-standin")
        #expect(!(try source.standIn()).contains("MAC-ACCESS"))
        #expect(!"\(try source.current())".contains("MAC-ACCESS"), "a token prints as its headers only")
    }

    @Test func withoutInferenceItIsNotSignedInTheWayTheRelayLends() {
        let clock = Clock()
        let keychain = FakeKeychain(.success(Self.item(access: "A", expiresIn: 3600, from: clock, scopes: ["user:profile"])))
        let source = signIn(keychain, clock)
        #expect(!source.isSignedIn)
        #expect(source.whyNot == .notSignedIn)
    }

    @Test func noItemIsNotSignedInAndAnUnreadableOneSaysSo() {
        let clock = Clock()
        #expect(signIn(FakeKeychain(.failure(.notSignedIn)), clock).whyNot == .notSignedIn)
        #expect(signIn(FakeKeychain(.failure(.unreadable)), clock).whyNot == .unreadable)
        #expect(signIn(FakeKeychain(.success(Data("not json".utf8))), clock).whyNot == .unreadable)
    }

    @Test func theTokenIsKeptUntilAMinuteBeforeItExpires() throws {
        let clock = Clock()
        let keychain = FakeKeychain(.success(Self.item(access: "FIRST", expiresIn: 600, from: clock)))
        let source = signIn(keychain, clock)
        _ = try source.current()
        keychain.item = .success(Self.item(access: "SECOND", expiresIn: 600, from: clock))
        #expect(try source.current().access == "FIRST")
        #expect(keychain.reads == 1)
        clock.now += 541
        #expect(try source.current().access == "SECOND")
        #expect(keychain.reads == 2)
    }

    @Test func aFailedReadIsNotRepeatedForAFewSeconds() {
        let clock = Clock()
        let keychain = FakeKeychain(.failure(.notSignedIn))
        let source = signIn(keychain, clock)
        #expect(!source.isSignedIn)
        #expect(!source.isSignedIn)
        #expect(keychain.reads == 1)
        clock.now += 6
        #expect(!source.isSignedIn)
        #expect(keychain.reads == 2)
    }

    /// A refused token: whatever the Keychain holds now is used if it is another, which is
    /// how a renewal by the Mac's own Claude is picked up. The same token is not retried.
    @Test func aRefusalReadsAfreshAndNeverHandsBackTheRefusedToken() async throws {
        let clock = Clock()
        let keychain = FakeKeychain(.success(Self.item(access: "OLD", expiresIn: 3600, from: clock)))
        let source = signIn(keychain, clock)
        let old = try source.current()
        await #expect(throws: MacSignInFailure.renewalRefused(401)) { try await source.renew(after: old) }
        keychain.item = .success(Self.item(access: "RENEWED-ON-THE-MAC", expiresIn: 3600, from: clock))
        let renewed = try await source.renew(after: old)
        #expect(renewed.access == "RENEWED-ON-THE-MAC")
        #expect(try source.current().access == "RENEWED-ON-THE-MAC")
    }

    /// The real `security`, against a service nobody has: "no such item" is not signed in.
    @Test func aMissingKeychainItemIsNotSignedIn() {
        let source = ClaudeKeychainSignIn(service: "agents-056-test-\(UUID().uuidString)")
        #expect(source.whyNot == .notSignedIn)
    }

    // MARK: Renewal by the Mac's own Claude (US3, research R6)

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// Two refused requests at once: the Mac's Claude is asked once, and both get its token.
    @Test func manyRefusalsAskTheMacsClaudeOnce() async throws {
        let clock = Clock()
        let keychain = FakeKeychain(.success(Self.item(access: "EXPIRED", expiresIn: -10, from: clock)))
        let asked = Counter()
        let source = ClaudeKeychainSignIn(reader: { try keychain.read() }, now: { clock.now }, renewer: {
            asked.add()
            try? await Task.sleep(for: .milliseconds(100))
            keychain.item = .success(Self.item(access: "RENEWED", expiresIn: 3600, from: clock))
        })
        let stale = MacSignInToken(access: "EXPIRED")
        async let first = source.renew(after: stale)
        async let second = source.renew(after: stale)
        let (a, b) = try await (first, second)
        #expect(a.access == "RENEWED" && b.access == "RENEWED")
        #expect(asked.count == 1)
    }

    /// Already renewed on the Mac: nothing is asked of Claude.
    @Test func aRenewalAlreadyMadeAsksNothing() async throws {
        let clock = Clock()
        let keychain = FakeKeychain(.success(Self.item(access: "NEWER", expiresIn: 3600, from: clock)))
        let asked = Counter()
        let source = ClaudeKeychainSignIn(reader: { try keychain.read() }, now: { clock.now }, renewer: { asked.add() })
        #expect(try await source.renew(after: MacSignInToken(access: "OLDER")).access == "NEWER")
        #expect(asked.count == 0)
    }

    /// Claude asked and nothing changed (signed out, revoked): refused, and the Mac's sign-in
    /// is left exactly as it was.
    @Test func aRenewalThatChangesNothingIsRefused() async throws {
        let clock = Clock()
        let keychain = FakeKeychain(.success(Self.item(access: "SAME", expiresIn: -10, from: clock)))
        let asked = Counter()
        let source = ClaudeKeychainSignIn(reader: { try keychain.read() }, now: { clock.now }, renewer: { asked.add() })
        await #expect(throws: MacSignInFailure.renewalRefused(401)) {
            try await source.renew(after: MacSignInToken(access: "SAME"))
        }
        #expect(asked.count == 1)
        #expect(try ClaudeKeychainSignIn.parse(try keychain.read()).0.access == "SAME")
    }
}
