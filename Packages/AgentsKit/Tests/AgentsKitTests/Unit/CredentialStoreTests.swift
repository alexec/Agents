#if canImport(Security)
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Keeping a runtime's credential on this Mac (043, FR-009, FR-010).
///
/// Against the real login Keychain, under a service name made for each test and removed
/// after it, so nothing here touches the app's own items.
@Suite("Keeping a credential", .serialized)
struct CredentialStoreTests {
    private func withStore(_ body: (CredentialStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cred-\(UUID().uuidString)")
        let store = CredentialStore(file: folder.appendingPathComponent("credentials.json"),
                                    service: "agents.test.\(UUID().uuidString)")
        defer {
            try? store.remove("claude")
            try? FileManager.default.removeItem(at: folder)
        }
        try body(store)
    }

    static let token = Secret("sk-ant-oat01-TESTSECRETTESTSECRET-a3f9")!
    static let key = Secret("sk-ant-api03-TESTSECRETTESTSECRET-9x9z")!

    @Test func aSavedSecretComesBackAndItsRecordIsOnlyTheMask() throws {
        try withStore { store in
            try store.save(Self.token, for: "claude")
            #expect(store.secret(for: "claude") == Self.token)
            let record = try #require(store.record(for: "claude"))
            #expect(record.kind == .oauthToken)
            #expect(record.mask == "sk-ant-oat…a3f9")
            let text = try String(contentsOf: store.file, encoding: .utf8)
            #expect(!text.contains("TESTSECRET"))
        }
    }

    @Test func replacingKeepsOnlyTheNewOne() throws {
        try withStore { store in
            try store.save(Self.token, for: "claude")
            try store.save(Self.key, for: "claude")
            #expect(store.secret(for: "claude") == Self.key)
            #expect(store.record(for: "claude")?.kind == .apiKey)
        }
    }

    @Test func removingLeavesNeitherSecretNorRecord() throws {
        try withStore { store in
            try store.save(Self.token, for: "claude")
            try store.remove("claude")
            #expect(store.secret(for: "claude") == nil)
            #expect(store.record(for: "claude") == nil)
        }
    }

    @Test func workedAndRefusedAreRemembered() throws {
        try withStore { store in
            try store.save(Self.token, for: "claude", at: Date(timeIntervalSince1970: 0))
            try store.markWorked("claude", at: Date(timeIntervalSince1970: 100))
            try store.markRefused("claude", at: Date(timeIntervalSince1970: 200))
            let record = try #require(store.record(for: "claude"))
            #expect(record.lastWorked == Date(timeIntervalSince1970: 100))
            #expect(record.lastRefused == Date(timeIntervalSince1970: 200))
        }
    }

    @Test func twoRootsNeverShareOne() {
        let a = CredentialStore(locations: StoreLocations(root: URL(filePath: "/tmp/root-a")))
        let b = CredentialStore(locations: StoreLocations(root: URL(filePath: "/tmp/root-b")))
        #expect(a.service != b.service)
        #expect(a.service.hasPrefix("agents.runtime-credential."))
    }
}
#endif
