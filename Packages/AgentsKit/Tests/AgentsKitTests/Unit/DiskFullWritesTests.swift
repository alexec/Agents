import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What is written while the disk is full survives, or is said truthfully (#212).
///
/// The disk is never filled: a full disk is a write that throws ENOSPC, through the
/// store's own seam, and a refusal is a folder this may not write to.
@Suite("Writes on a full disk")
struct DiskFullWritesTests {
    private func store() throws -> (AgentStore, StoreLocations) {
        let root = FileManager.default.temporaryDirectory.appending(path: "diskfull-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        return (try AgentStore(locations: locations), locations)
    }

    private static let full = POSIXError(.ENOSPC)

    private func said(_ store: AgentStore, _ id: UUID) async throws -> [String] {
        try await store.transcript(for: id).entries.compactMap { $0.text }
    }

    // MARK: Chat lines

    @Test func linesTheDiskRefusesAreWrittenInOrderOnceThereIsSpace() async throws {
        let (store, _) = try store()
        let id = UUID()
        try await store.append(TranscriptEntry(kind: .runtimeNote("one")), for: id)
        await store.refuseWrites(Self.full)
        for word in ["two", "three"] {
            await #expect(throws: POSIXError.self) {
                try await store.append(TranscriptEntry(kind: .runtimeNote(word)), for: id)
            }
        }
        #expect(await store.heldLines(of: id).lines == 2)
        #expect(await store.holdsLines)

        await store.refuseWrites(nil)
        try await store.append(TranscriptEntry(kind: .runtimeNote("four")), for: id)
        #expect(try await said(store, id) == ["one", "two", "three", "four"])
        #expect(await store.heldLines(of: id).lines == 0)
        #expect(!(await store.holdsLines))
    }

    @Test func aQuietAgentsLinesAreWrittenWhenTriedAgain() async throws {
        let (store, _) = try store()
        let id = UUID()
        await store.refuseWrites(Self.full)
        _ = try? await store.append(TranscriptEntry(kind: .runtimeNote("held")), for: id)
        #expect(await store.keepHeld() != nil, "still full: said again, kept")
        #expect(await store.heldLines(of: id).lines == 1)

        await store.refuseWrites(nil)
        #expect(await store.keepHeld() == nil)
        #expect(try await said(store, id) == ["held"])
    }

    @Test func pastTheHoldTheOldestGoAndTheChatSaysHowMany() async throws {
        let (store, _) = try store()
        let id = UUID()
        await store.refuseWrites(Self.full)
        let big = String(repeating: "x", count: 100_000)
        for index in 0..<15 {
            _ = try? await store.append(TranscriptEntry(kind: .runtimeNote("\(index) \(big)")), for: id)
        }
        let held = await store.heldLines(of: id)
        #expect(held.dropped > 0)
        #expect(held.lines + held.dropped == 15)

        await store.refuseWrites(nil)
        #expect(await store.keepHeld() == nil)
        let entries = try await store.transcript(for: id).entries
        guard case .notice(let notice) = entries.first?.kind else {
            Issue.record("the gap is said first, where the lines went")
            return
        }
        #expect(notice.title.hasPrefix("\(held.dropped) lines"))
        #expect(entries.count == held.lines + 1)
        #expect(entries.last?.text?.hasPrefix("14 ") == true, "the newest are the ones kept")
    }

    // MARK: Disk full is not "doesn't exist"

    @Test func aFileThatCannotBeMadeSaysWhy() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "locked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        do {
            _ = try StoreCoding.openForAdding(folder.appending(path: "app-tools.jsonl"))
            Issue.record("a folder this may not write to made a file")
        } catch {
            #expect(WriteFailure(error, keeping: "x")?.cause == .notAllowed)
        }
        #expect(WriteFailure(StoreCoding.writeError(ENOSPC, at: folder), keeping: "x")?.cause == .diskFull)
    }

    @Test func anEventTheDiskRefusesComesBackToBeTold() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        let events = EventStore(locations: StoreLocations(root: root))
        let error = events.append(.repeatOf(1, at: Date(), count: 2))
        #expect(error.flatMap { WriteFailure($0, keeping: "an event") }?.cause == .notAllowed)
        #expect(events.saveState(EventState()) != nil)
    }

    // MARK: Key files

    @Test func anEmptyKeyFileLeftByAFullDiskIsMadeAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "control-host-key")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let key = try ControlAgreement.loadOrMake(file: file, now: Date().addingTimeInterval(60))
        #expect(key.count == 32)
        #expect(try Data(contentsOf: file) == key)
        #expect(try ControlAgreement.loadOrMake(file: file) == key, "the same key the next time")
    }

    @Test func aKeyFileBeingWrittenNowIsNotTakenForTorn() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "control-host-key")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        #expect(!ControlAgreement.isTorn(file, now: Date()))
        #expect(ControlAgreement.isTorn(file, now: Date().addingTimeInterval(60)))
    }

    @Test func aKeyTheDiskRefusesLeavesNoFileBehind() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let file = folder.appending(path: "control-host-key")
        #expect(throws: (any Error).self) { try ControlAgreement.loadOrMake(file: file) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
