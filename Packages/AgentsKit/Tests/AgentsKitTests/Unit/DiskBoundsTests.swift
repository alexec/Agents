import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the app keeps on disk for itself has a bound (#211).
@Suite("Disk bounds", .timeLimit(.minutes(1)))
struct DiskBoundsTests {
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Short, because the daemon's socket path has to fit in 104 bytes.
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/agd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func make(_ url: URL, changed: Date, folder: Bool = false) throws {
        if folder {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("inside"))
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    // MARK: Pinned helpers

    /// The issue's own test: after 10 ships, `helpers/` holds at most 3 copies plus those in
    /// use. Since #185 nothing starts a pinned copy, so each start takes the folder away
    /// whole; removing a file a process still runs is safe, since the process keeps it.
    @Test func afterTenShipsNoPinnedHelperIsLeft() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        for ship in 1...10 {
            // What a build before #185 left behind as it started.
            try make(locations.helpers.appendingPathComponent("agentsd-\(ship)"), changed: Date())
            let daemon = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
            await daemon.shutDown()
            #expect(names(in: locations.helpers).count <= 3)
        }
        #expect(!FileManager.default.fileExists(atPath: locations.helpers.path))
    }

    // MARK: Launch sweeps

    @Test func aStartRemovesAnEarlierRunsSkillPreviews() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        try make(locations.catalogStaging.appendingPathComponent(UUID().uuidString), changed: Date(), folder: true)
        let daemon = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await daemon.shutDown()
        #expect(!FileManager.default.fileExists(atPath: locations.catalogStaging.path))
    }

    @Test func openCodesTemporaryFolderLosesWhatIsOverADayOld() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let temporary = root.appendingPathComponent("runtimes/opencode/tmp", isDirectory: true)
        try make(temporary.appendingPathComponent("TemporaryDirectory.old"), changed: now.addingTimeInterval(-2 * day), folder: true)
        try make(temporary.appendingPathComponent("stale.txt"), changed: now.addingTimeInterval(-1.5 * day))
        try make(temporary.appendingPathComponent("TemporaryDirectory.new"), changed: now.addingTimeInterval(-3_600), folder: true)
        // A link out of the folder goes as a link; what it points to stays.
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try make(outside, changed: now.addingTimeInterval(-10 * day), folder: true)
        let link = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let past = [timeval(tv_sec: Int(now.timeIntervalSince1970 - 3 * day), tv_usec: 0),
                    timeval(tv_sec: Int(now.timeIntervalSince1970 - 3 * day), tv_usec: 0)]
        _ = lutimes(link.path, past)

        DiskSweep.runtimeTemporaries(locations, now: now)

        #expect(names(in: temporary) == ["TemporaryDirectory.new"])
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("inside").path))
    }

    @Test func aMissingFolderIsNothingToSweep() {
        let nowhere = URL(fileURLWithPath: "/tmp/agd-none-\(UUID().uuidString)")
        #expect(DiskSweep.removeOlder(than: day, in: nowhere, now: now) == 0)
        #expect(DiskSweep.keepNewest(3, in: nowhere) == 0)
    }

    // MARK: Crash notes

    @Test func crashNotesKeepTheNewestAndNothingElseIsTouched() throws {
        let crashes = try root()
        defer { try? FileManager.default.removeItem(at: crashes) }
        for n in 0..<25 {
            try make(crashes.appendingPathComponent(String(format: "crash-%02d.txt", n)),
                     changed: now.addingTimeInterval(TimeInterval(n) * 60))
        }
        try make(crashes.appendingPathComponent("notes.txt"), changed: now.addingTimeInterval(-10 * day))

        #expect(DiskSweep.keepNewest(DiskSweep.crashNotesKept, named: "crash-", in: crashes) == 5)

        let left = names(in: crashes)
        #expect(left.count == DiskSweep.crashNotesKept + 1)
        #expect(left.contains("notes.txt"))
        #expect(!left.contains("crash-04.txt"))
        #expect(left.contains("crash-05.txt"))
        #expect(left.contains("crash-24.txt"))
    }

    // MARK: relay.log

    @Test func theRelayLogRollsAtAMegabyte() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let relays = HostSignInRelays(locations: locations)
        let line = String(repeating: "x", count: 1_000)
        for _ in 0..<2_500 { relays.write(line) }

        let log = locations.hostsFolder.appendingPathComponent("relay.log")
        let previous = locations.hostsFolder.appendingPathComponent("relay.previous.log")
        let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
        #expect(size(log) <= 1024 * 1024)
        #expect(size(previous) <= 1024 * 1024)
        #expect(size(previous) > 0)
    }
}
