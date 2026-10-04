#if canImport(Security)
import Foundation
import Security
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
            try? store.remove("gemini")
            try? store.remove("claude")
            try? FileManager.default.removeItem(at: folder)
        }
        try body(store)
    }

    static let token = Secret("AQ." + "Ab8RN6FAKESTORETESTSECRET-a3f9")!
    static let key = Secret("AIza" + "SyFAKESTORETESTSECRETSECOND9x9z")!

    @Test func aSavedSecretComesBackAndItsRecordIsOnlyTheMask() throws {
        try withStore { store in
            try store.save(Self.token, for: "gemini")
            #expect(store.secret(for: "gemini") == Self.token)
            let record = try #require(store.record(for: "gemini"))
            #expect(record.kind == .geminiAPIKey)
            #expect(record.mask == "key …a3f9")
            let text = try String(contentsOf: store.file, encoding: .utf8)
            #expect(!text.contains("TESTSECRET"))
        }
    }

    @Test(.slowUnderLoad) func replacingKeepsOnlyTheNewOne() throws {
        try withStore { store in
            try store.save(Self.token, for: "gemini")
            try store.save(Self.key, for: "gemini")
            #expect(store.secret(for: "gemini") == Self.key)
            #expect(store.record(for: "gemini")?.lastFour == "9x9z")
        }
    }

    /// A record of a kind this version no longer takes (047's OpenAI key) drops alone.
    @Test func aRecordOfAKindNoLongerTakenLeavesTheOthers() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(#"""
            {"codex":{"kind":"openAIAPIKey","lastFour":"1234","addedAt":"2026-09-25T10:00:00Z"},
             "gemini":{"kind":"geminiAPIKey","lastFour":"abcd","addedAt":"2026-09-25T10:00:00Z"}}
            """#.utf8).write(to: store.file)
            #expect(store.record(for: "codex") == nil)
            #expect(store.record(for: "gemini")?.kind == .geminiAPIKey)
        }
    }

    @Test func removingLeavesNeitherSecretNorRecord() throws {
        try withStore { store in
            try store.save(Self.token, for: "gemini")
            try store.remove("gemini")
            #expect(store.secret(for: "gemini") == nil)
            #expect(store.record(for: "gemini") == nil)
        }
    }

    @Test func workedAndRefusedAreRemembered() throws {
        try withStore { store in
            try store.save(Self.token, for: "gemini", at: Date(timeIntervalSince1970: 0))
            try store.markWorked("gemini", at: Date(timeIntervalSince1970: 100))
            try store.markRefused("gemini", at: Date(timeIntervalSince1970: 200))
            let record = try #require(store.record(for: "gemini"))
            #expect(record.lastWorked == Date(timeIntervalSince1970: 100))
            #expect(record.lastRefused == Date(timeIntervalSince1970: 200))
        }
    }

    /// A Claude token saved before 056 is forgotten, record and Keychain item both; a
    /// Gemini key beside it stays (FR-010).
    @Test func aClaudeTokenFromBefore056IsForgottenAndGeminisKept() throws {
        try withStore { store in
            try store.save(Self.token, for: "gemini")
            let item: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
                kSecAttrAccount as String: "claude", kSecValueData as String: Data("sk-ant-oat01-OLDTOKEN".utf8)]
            #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
            var all = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
            all["claude"] = ["kind": "oauthToken", "lastFour": "KEN0", "addedAt": "2026-09-20T10:00:00Z"]
            try JSONSerialization.data(withJSONObject: all).write(to: store.file)

            #expect(store.forgetKindsNoLongerTaken() == ["claude"])
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: store.service, kSecAttrAccount as String: "claude"]
            #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
            let text = try String(contentsOf: store.file, encoding: .utf8)
            #expect(!text.contains("claude"))
            #expect(store.secret(for: "gemini") == Self.token)
            #expect(store.forgetKindsNoLongerTaken().isEmpty, "once")
        }
    }

    private func keychainHas(_ store: CredentialStore, _ account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: store.service, kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func addItem(_ store: CredentialStore, _ account: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
            kSecAttrAccount as String: account, kSecValueData as String: Data("future-secret".utf8)]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
    }

    /// A kind a newer build added is not this build's to forget (#205): swapping builds
    /// keeps its record and its Keychain item, and a save beside it carries it through.
    @Test func aNewerBuildsKindIsKeptRecordAndSecret() throws {
        try withStore { store in
            defer { try? store.remove("future") }
            try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(#"{"future":{"kind":"futureKey","lastFour":"9999","addedAt":"2026-10-04T10:00:00Z"}}"#.utf8)
                .write(to: store.file)
            addItem(store, "future")

            #expect(store.forgetKindsNoLongerTaken().isEmpty)
            #expect(keychainHas(store, "future"))
            try store.save(Self.token, for: "gemini")
            try store.markWorked("future")
            let text = try String(contentsOf: store.file, encoding: .utf8)
            #expect(text.contains("futureKey") && text.contains("9999"), "the newer record is carried through")
            #expect(store.record(for: "gemini") != nil)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: store.service, kSecAttrAccount as String: "future"]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// A records file that cannot be read, by permissions or by its bytes, is never
    /// written over with one runtime, and the Keychain is left as it was.
    @Test(arguments: ["permissions", "corrupt", "conflict"])
    func anUnreadableRecordsFileIsNeverWrittenOver(_ how: String) throws {
        try withStore { store in
            try store.save(Self.token, for: "gemini")
            var bytes = try Data(contentsOf: store.file)
            switch how {
            case "corrupt": bytes = Data(#"{"gemini":{"kind":"gem"#.utf8)
            case "conflict": bytes = Data("<<<<<<< HEAD\n".utf8) + bytes + Data("=======\n>>>>>>> b\n".utf8)
            default: break
            }
            try bytes.write(to: store.file)
            if how == "permissions" {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.file.path)
            }
            #expect(store.isUnreadable)
            #expect(throws: CredentialStore.Unreadable.self) { try store.save(Self.key, for: "gemini") }
            #expect(throws: CredentialStore.Unreadable.self) { try store.remove("gemini") }
            #expect(throws: CredentialStore.Unreadable.self) { try store.markWorked("gemini") }
            #expect(store.forgetKindsNoLongerTaken().isEmpty)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
            #expect(try Data(contentsOf: store.file) == bytes, "byte for byte")
            #expect(store.secret(for: "gemini") == Self.token, "the Keychain item is untouched")
            try FileManager.default.removeItem(at: store.file)
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
