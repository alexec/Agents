import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A transcript written onto a disk that fills up (073): the entry that did not fit fails
/// with an error the caller sees, and once there is room again every entry written before
/// and after it still reads. And the daemon on that disk (#88): a prompt it cannot write
/// fails in words with nothing queued, and a line of a chat it cannot keep is told.
///
///   AGENTS_DISK_FULL=1 swift test --filter DiskFull
///
/// It makes a two-megabyte disk image under /tmp, mounts it with `-nobrowse` so Finder
/// does not show it, fills it, and detaches it at the end.
@Suite("A disk that fills up", .serialized, .timeLimit(.minutes(2)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_DISK_FULL"] != nil))
struct DiskFullLiveTests {
    private func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") failed"])
        }
    }

    /// A two-megabyte disk, mounted for the length of `body` and gone after.
    private func onATinyDisk(_ body: (URL) async throws -> Void) async throws {
        let name = "agdf-\(UUID().uuidString.prefix(6))"
        let image = URL(filePath: "/tmp/\(name).dmg")
        let mount = URL(filePath: "/tmp/\(name)", directoryHint: .isDirectory)
        try hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", name, image.path])
        try hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer {
            try? hdiutil(["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: image)
        }
        try await body(mount)
    }

    /// Every last byte taken, the way a download that ran out of room leaves it: in
    /// smaller and smaller pieces until not one more fits.
    private func fill(_ file: URL) throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var size = 1 << 20
        while size > 0 {
            do { try handle.write(contentsOf: Data(count: size)) } catch { size /= 2 }
        }
    }

    @Test func aTranscriptOnAFullDiskLosesOnlyTheEntryThatDidNotFit() async throws {
        try await onATinyDisk { mount in try await transcriptOnAFullDisk(mount) }
    }

    private func transcriptOnAFullDisk(_ mount: URL) async throws {
        let store = try AgentStore(locations: StoreLocations(root: mount.appending(path: "root")))
        // Something else has most of the disk, as a build or a download does in life.
        let filler = mount.appending(path: "filler")
        try Data(count: 1_200_000).write(to: filler)

        let agent = UUID()
        let words = String(repeating: "a long line of output from a tool ", count: 120)
        var written = 0
        var refused = false
        for index in 0 ..< 1_000 {
            do {
                try await store.append(TranscriptEntry(kind: .userMessage("\(index) \(words)")), for: agent)
                written += 1
            } catch {
                refused = true
                break
            }
        }
        #expect(refused, "the disk never filled")
        #expect(written > 10)

        // Room again, as when the build is cleaned or the Trash emptied.
        try FileManager.default.removeItem(at: filler)

        try await store.append(TranscriptEntry(kind: .userMessage("after")), for: agent)
        let page = try await store.transcript(for: agent, limit: 10_000)
        let asked = page.entries.compactMap { entry -> String? in
            if case .userMessage(let text, _, _) = entry.kind { return text } else { return nil }
        }
        #expect(asked.count == written + 1, "every entry that was written reads, and the one after")
        #expect(asked.last == "after")
    }

    @Test func theDaemonOnAFullDiskSaysSoAndQueuesNothingItCouldNotKeep() async throws {
        try await onATinyDisk { mount in
            let locations = StoreLocations(root: mount.appending(path: "root"))
            let work = mount.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                                  discovery: .findsEverything,
                                  launcher: FakeLauncher(script: FakeACPAgent.Script()))
            let heard = WriteFailureRecorder()
            await heard.attach(to: core)
            let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
            await eventually("the first turn ended") { await core.agent(id)?.state == .finished }

            let filler = mount.appending(path: "filler")
            try fill(filler)

            // The person's words: refused, in words, with nothing queued behind the refusal.
            var refusal: JSONRPCError?
            do { try await core.prompt(.init(agentID: id, text: "two")) } catch { refusal = error as? JSONRPCError }
            #expect(refusal?.code == DaemonAPI.Failure.couldNotSave)
            #expect(refusal?.message == "Your Mac is out of disk space, so your message could not be saved. Free some space, then try again.")
            #expect(await core.agent(id)?.queuedPrompts.isEmpty == true)

            // A line nobody asked for: told to every window, once. Longer than the slack
            // left in the transcript's last block, which a short line would still fit.
            let long = String(repeating: "output from a tool ", count: 1_000)
            await core.record(.runtimeNote(long), for: id)
            await core.record(.runtimeNote(long), for: id)
            #expect(heard.failures.map(\.cause) == [.diskFull], "\(heard.failures)")
            #expect(heard.failures.first?.message.hasPrefix("Your Mac is out of disk space, so a line of") == true)

            // Room again: the same words go.
            try FileManager.default.removeItem(at: filler)
            try await core.prompt(.init(agentID: id, text: "two"))
            await eventually("the second turn ran") {
                let entries = (try? await core.transcript(.init(agentID: id)).entries) ?? []
                return entries.contains { if case .userMessage("two", _, _) = $0.kind { true } else { false } }
            }
        }
    }
}
