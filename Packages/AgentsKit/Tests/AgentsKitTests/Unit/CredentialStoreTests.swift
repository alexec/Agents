#if canImport(Security)
import Foundation
import Security
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Keeping a runtime's credential on this Mac (043, FR-009, FR-010).
///
/// `CredentialKind` has no case now that Gemini, its last, is retired (#3043), so `Secret`
/// can never be constructed and `save`/`record`/`secret` are untestable from outside this
/// file's own type (the failable initialiser is the only way in, and it always refuses).
/// What is still tested: a kind this build does not know is carried through untouched,
/// against the real login Keychain, under a service name made for each test and removed
/// after it, so nothing here touches the app's own items.
@Suite("Keeping a credential", .serialized)
struct CredentialStoreTests {
    private func withStore(_ body: (CredentialStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cred-\(UUID().uuidString)")
        let store = CredentialStore(file: folder.appendingPathComponent("credentials.json"),
                                    service: "agents.test.\(UUID().uuidString)")
        defer {
            try? store.remove("future")
            try? FileManager.default.removeItem(at: folder)
        }
        try body(store)
    }

    private func addItem(_ store: CredentialStore, _ account: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service,
            kSecAttrAccount as String: account, kSecValueData as String: Data("future-secret".utf8)]
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
    }

    private func keychainHas(_ store: CredentialStore, _ account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: store.service, kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// A kind this build does not know (Gemini's own, or a newer build's) is never this
    /// build's to decode, read, or write over: its record and its Keychain item are left
    /// exactly as they were.
    @Test func aKindThisBuildDoesNotKnowIsKept() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(#"{"future":{"kind":"futureKey","lastFour":"9999","addedAt":"2026-10-04T10:00:00Z"}}"#.utf8)
                .write(to: store.file)
            addItem(store, "future")

            #expect(store.record(for: "future") == nil)
            #expect(keychainHas(store, "future"))
            try store.markWorked("future")
            let text = try String(contentsOf: store.file, encoding: .utf8)
            #expect(text.contains("futureKey") && text.contains("9999"), "the record is carried through untouched")
            try store.remove("future")
            #expect(!keychainHas(store, "future"), "removing still takes the Keychain item away")
            let afterRemove = try String(contentsOf: store.file, encoding: .utf8)
            #expect(afterRemove.contains("futureKey"), "but its record, undecodable, is left")
        }
    }

    /// A records file that cannot be read, by permissions or by its bytes, is never
    /// written over, and the Keychain is left as it was.
    @Test(arguments: ["permissions", "corrupt", "conflict"])
    func anUnreadableRecordsFileIsNeverWrittenOver(_ how: String) throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var bytes = Data(#"{"future":{"kind":"futureKey","lastFour":"9999","addedAt":"2026-10-04T10:00:00Z"}}"#.utf8)
            addItem(store, "future")
            switch how {
            case "corrupt": bytes = Data(#"{"future":{"kind":"fut"#.utf8)
            case "conflict": bytes = Data("<<<<<<< HEAD\n".utf8) + bytes + Data("=======\n>>>>>>> b\n".utf8)
            default: break
            }
            try bytes.write(to: store.file)
            if how == "permissions" {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.file.path)
            }
            #expect(store.isUnreadable)
            #expect(throws: CredentialStore.Unreadable.self) { try store.remove("future") }
            #expect(throws: CredentialStore.Unreadable.self) { try store.markWorked("future") }
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
            #expect(try Data(contentsOf: store.file) == bytes, "byte for byte")
            #expect(keychainHas(store, "future"), "the Keychain item is untouched")
            try FileManager.default.removeItem(at: store.file)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: store.service, kSecAttrAccount as String: "future"]
            SecItemDelete(query as CFDictionary)
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
