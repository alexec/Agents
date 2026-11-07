import Foundation
import Testing
@testable import AgentsKitCore

/// What a copy of the app leaves on the device goes (#3747): old output copies, older
/// voice models, and the keys of walks that are gone. Scratch folders and a scratch
/// keychain service only, never the device's own items.
@Suite("Leftovers are swept")
struct LeftoversTests {
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("leftovers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func file(_ name: String, in folder: URL, changed: Date) throws {
        let url = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
    }

    @Test("Only old files with the prefix go")
    func removesOldFilesWithThePrefix() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        try file("agents-output-old.txt", in: folder, changed: now.addingTimeInterval(-2 * 24 * 3600))
        try file("agents-output-new.txt", in: folder, changed: now.addingTimeInterval(-60))
        try file("other-old.txt", in: folder, changed: now.addingTimeInterval(-2 * 24 * 3600))

        let removed = Leftovers.removeOld(in: folder, prefix: "agents-output-", olderThan: 24 * 3600, now: now)

        #expect(removed == 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["agents-output-new.txt", "other-old.txt"])
    }

    @Test("Entries the current version does not name go")
    func removesWhatIsNotKept() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["KokoroTail.mlmodelc", "KokoroTail_v2.mlmodelc", "af_heart.bin"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }

        let removed = Leftovers.removeAll(in: folder, except: ["KokoroTail_v2.mlmodelc", "af_heart.bin"])

        #expect(removed == 1)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["KokoroTail_v2.mlmodelc", "af_heart.bin"])
    }

    @Test("Missing folders remove nothing")
    func missingFolder() {
        let folder = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(Leftovers.removeOld(in: folder, prefix: "agents-output-", olderThan: 0) == 0)
        #expect(Leftovers.removeAll(in: folder, except: []) == 0)
    }

    #if canImport(CryptoKit) && os(macOS)
    @Test("A gone walk's keys go; a live walk's and the person's stay")
    func deletesGoneWalkKeys() throws {
        let keychain = DeviceKey.Keychain(accessGroup: nil, service: "com.alexecollins.agents.test.\(UUID().uuidString)")
        let accounts = ["control-client-key", "lock-signing-key",
                        "control-client-key.walk.gone", "lock-signing-key.walk.gone",
                        "control-client-key.walk.live"]
        defer { accounts.forEach { keychain.delete(account: $0) } }
        do {
            for account in accounts { try keychain.write(Data("k".utf8), account: account) }
        } catch {
            // No keychain to write to (a locked one on CI): nothing to sweep.
            return
        }

        let deleted = ControlClientKey.deleteWalkKeys(in: keychain) { $0 == "gone" }

        #expect(deleted.sorted() == ["control-client-key.walk.gone", "lock-signing-key.walk.gone"])
        #expect(keychain.accounts().sorted() == ["control-client-key", "control-client-key.walk.live", "lock-signing-key"])
    }
    #endif
}
