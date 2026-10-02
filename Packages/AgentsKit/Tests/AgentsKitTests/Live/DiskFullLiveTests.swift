import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A transcript written onto a disk that fills up (073): the entry that did not fit fails
/// with an error the caller sees, and once there is room again every entry written before
/// and after it still reads.
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

    @Test func aTranscriptOnAFullDiskLosesOnlyTheEntryThatDidNotFit() async throws {
        let name = "agdf-\(UUID().uuidString.prefix(6))"
        let image = URL(filePath: "/tmp/\(name).dmg")
        let mount = URL(filePath: "/tmp/\(name)", directoryHint: .isDirectory)
        try hdiutil(["create", "-size", "2m", "-fs", "HFS+", "-volname", name, image.path])
        try hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer {
            try? hdiutil(["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: image)
        }

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
}
