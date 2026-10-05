import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The #171 rule, finished (#205): only a file that reads and does not decode is set
/// aside; one that does not read is tried again, then held for the run and never
/// written over; a project's file is copied under the daemon's root, never set aside in
/// the person's tree; and at most three copies of one file are kept.
@Suite("Unreadable stores are held, not emptied", .timeLimit(.minutes(1)))
struct UnreadableStoresHeldTests {
    private let fileManager = FileManager.default

    private func temporary() throws -> StoreLocations {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnreadableHeld-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return StoreLocations(root: root)
    }

    private func names(_ folder: URL) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func device(_ name: String) -> Device {
        Device(id: UUID(), publicKey: Data([1, 2, 3]), name: name, kind: .iPhone,
               announcedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private struct ReadError: Error {}

    /// A reader that fails the first `failures` reads, then reads the disk.
    private final class Flaky: @unchecked Sendable {
        let lock = NSLock()
        var failures: Int
        init(_ failures: Int) { self.failures = failures }
        func read(_ url: URL) throws -> Data {
            let fail = lock.withLock { () -> Bool in
                guard failures > 0 else { return false }
                failures -= 1
                return true
            }
            if fail { throw ReadError() }
            return try Data(contentsOf: url)
        }
    }

    // MARK: Read errors

    @Test func aReadErrorThatPassesIsReadOnTheSecondTry() throws {
        let locations = try temporary()
        let store = DeviceStore(locations: locations)
        try store.save([device("Phone")])
        let flaky = Flaky(1)
        let devices = StoreFile.$reader.withValue({ try flaky.read($0) }) { store.load() }
        #expect(devices.map(\.name) == ["Phone"])
        #expect(names(locations.root).filter { $0.contains(".corrupt-") }.isEmpty)
        try store.save([device("Phone"), device("Pad")])
    }

    /// EMFILE, EIO, a root-owned file: a good `devices.json` is not moved aside. It is left
    /// byte for byte, the store reads as empty, and no save writes over it this run.
    @Test func aReadErrorThatStaysHoldsTheStoreForTheRun() throws {
        let locations = try temporary()
        let store = DeviceStore(locations: locations)
        try store.save([device("Phone")])
        let before = try Data(contentsOf: locations.devices)

        let flaky = Flaky(2)
        let devices = StoreFile.$reader.withValue({ try flaky.read($0) }) { store.load() }
        #expect(devices.isEmpty)
        #expect(throws: StoreFile.Held.self) { try store.save([device("Other")]) }
        #expect(try Data(contentsOf: locations.devices) == before)
        #expect(names(locations.root).filter { $0.contains(".corrupt-") }.isEmpty, "nothing moved aside")
        #expect(SetAsideNotes.shared.note(for: locations.devices)?.contains("until Agents restarts") == true)
        // Reading again this run does not lift it.
        #expect(store.load().map(\.name) == ["Phone"])
        #expect(throws: StoreFile.Held.self) { try store.save([device("Other")]) }
    }

    @Test func aFileThatMayNotBeReadIsHeldNotSetAside() throws {
        let locations = try temporary()
        let store = ProjectStore(locations: locations)
        let projects = [Project(folder: locations.root.appendingPathComponent("p"))]
        try store.save(projects)
        let before = try Data(contentsOf: locations.projects)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: locations.projects.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locations.projects.path) }

        #expect(store.load().isEmpty)
        #expect(throws: StoreFile.Held.self) { try store.save([]) }
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locations.projects.path)
        #expect(try Data(contentsOf: locations.projects) == before)
        #expect(names(locations.root).filter { $0.contains(".corrupt-") }.isEmpty)
    }

    // MARK: Decode errors

    /// A newer build's value (a limit in a shape this build does not know) and conflict markers
    /// both decode-fail: set aside, byte for byte, and then the store carries on.
    @Test(arguments: [
        #"{"daily":{"credits":5,"window":"week"}}"#,
        "<<<<<<< HEAD\n[]\n=======\n[]\n>>>>>>> b\n",
    ])
    func aFileThatDoesNotDecodeIsSetAsideByteForByte(_ text: String) throws {
        let locations = try temporary()
        let bytes = Data(text.utf8)
        try bytes.write(to: locations.limits)
        #expect(LimitStore(locations: locations).load() == CostLimits())
        let kept = StoreCoding.asides(of: locations.limits)
        #expect(kept.count == 1)
        #expect(try kept.first.map { try Data(contentsOf: $0) } == bytes)
    }

    @Test func atMostThreeCopiesOfOneFileAreKept() throws {
        let locations = try temporary()
        let url = locations.root.appendingPathComponent("x.json")
        var made: [URL] = []
        for n in 0..<5 {
            try Data("garbage \(n)".utf8).write(to: url)
            made.append(try #require(StoreCoding.setAside(url)))
        }
        let kept = StoreCoding.asides(of: url)
        try #require(kept == Array(made.suffix(3)), "the newest three")
        #expect(try Data(contentsOf: kept[2]) == Data("garbage 4".utf8))
    }

    // MARK: A project's files

    private func order(_ tiles: [String]) -> DashboardOrder {
        DashboardOrder(sections: [DashboardOrderSection(title: nil, tiles: tiles)])
    }

    /// `_order.json` mid-merge: left where it is, copied under the daemon's root once for
    /// its bytes, every move refused until it reads.
    @Test func aProjectFileIsCopiedUnderTheRootAndLeftAlone() throws {
        let locations = try temporary()
        let project = locations.root.deletingLastPathComponent().appendingPathComponent("proj-\(UUID().uuidString)")
        let dashboard = DashboardStore(locations: locations)
        let url = DashboardStore.orderFile(project)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let conflicted = Data("<<<<<<< HEAD\n{\"sections\":[{\"tiles\":[\"a\"]}]}\n=======\n{\"sections\":[]}\n>>>>>>> b\n".utf8)
        try conflicted.write(to: url)

        #expect(dashboard.readOrder(project) == nil)
        #expect(dashboard.readOrder(project) == nil)
        #expect(throws: StoreFile.Held.self) { try dashboard.writeOrder(order(["c"]), in: project) }
        #expect(throws: StoreFile.Held.self) { try dashboard.writeOrder(DashboardOrder(), in: project) }
        #expect(try Data(contentsOf: url) == conflicted)
        #expect(names(url.deletingLastPathComponent()) == ["_order.json"], "nothing set aside in the project")
        let kept = StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: locations.root))
        #expect(kept.count == 1, "one copy for the same bytes, however often read")
        #expect(dashboard.notes(project)?.contains("_order.json") == true)

        try Data(#"{"sections":[{"tiles":["a"]}]}"#.utf8).write(to: url)
        #expect(dashboard.readOrder(project) == order(["a"]))
        try dashboard.writeOrder(order(["a", "c"]), in: project)
        #expect(dashboard.notes(project) == nil)
    }

    /// A history with a bad line: the whole file is copied under the root (never into
    /// the project), once, and the copies are not counted as history.
    @Test func aHistoryWithABadLineIsCopiedOutsideOnce() throws {
        let locations = try temporary()
        let project = locations.root.deletingLastPathComponent().appendingPathComponent("proj-\(UUID().uuidString)")
        let dashboard = DashboardStore(locations: locations)
        let folder = DashboardStore.historyFolder(project)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("t.jsonl")
        let bytes = Data("{\"t\":1800000000,\"v\":1}\nnot a point\n{\"t\":1800003600,\"v\":2}\n".utf8)
        try bytes.write(to: url)

        #expect(dashboard.points(project, "t").map(\.value) == [1, 2])
        let fresh = DashboardStore(locations: locations)
        _ = fresh.points(project, "t")
        #expect(names(folder) == ["t.jsonl"])
        let kept = StoreCoding.asides(of: url, in: StoreCoding.asideFolder(for: url, under: locations.root))
        #expect(kept.count == 1)
        #expect(try kept.first.map { try Data(contentsOf: $0) } == bytes)
        #expect(dashboard.historyBytes(project) == bytes.count)
    }

    @Test func aHistoryThatDoesNotReadIsNotRewrittenWithOnePoint() throws {
        let locations = try temporary()
        let project = locations.root.deletingLastPathComponent().appendingPathComponent("proj-\(UUID().uuidString)")
        let dashboard = DashboardStore(locations: locations)
        let folder = DashboardStore.historyFolder(project)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("t.jsonl")
        let bytes = Data("{\"t\":1800000000,\"v\":1}\n".utf8)
        try bytes.write(to: url)

        let flaky = Flaky(2)
        StoreFile.$reader.withValue({ try flaky.read($0) }) {
            #expect(dashboard.points(project, "t").isEmpty)
        }
        #expect(throws: StoreFile.Held.self) {
            try dashboard.record(5, at: Date(timeIntervalSince1970: 1_800_100_000), for: "t", in: project)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    // MARK: The rest

    @Test func eventsThatDoNotReadAreNotPrunedAway() throws {
        let locations = try temporary()
        let bytes = Data("{\"event\":{}}\n".utf8)
        try bytes.write(to: locations.events)
        let store = EventStore(locations: locations)
        let flaky = Flaky(2)
        let log = StoreFile.$reader.withValue({ try flaky.read($0) }) { store.load() }
        #expect(log.events.isEmpty)
        store.rewrite(log)
        #expect(try Data(contentsOf: locations.events) == bytes)
    }

    @Test func aSidecarThatDoesNotReadIsNotWrittenOver() throws {
        let locations = try temporary()
        let url = locations.root.appendingPathComponent("catalog-mcp.json")
        var side = MCPCatalogSidecar()
        side.upsert(destination: .personal, name: "pg",
                    record: .init(registryName: "r/pg", version: "1", run: "npx", addedAt: Date(timeIntervalSince1970: 0)))
        try side.save(to: url)
        let before = try Data(contentsOf: url)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        var read = MCPCatalogSidecar.load(from: url)
        #expect(read.servers.isEmpty)
        read.upsert(destination: .personal, name: "other",
                    record: .init(registryName: "r/o", version: "1", run: "npx", addedAt: Date()))
        #expect(throws: StoreFile.Held.self) { try read.save(to: url) }
        #expect(throws: StoreFile.Held.self) { try CatalogSidecar().save(to: url) { _ in true } }
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aSkillLockThatDoesNotReadIsRefused() throws {
        let locations = try temporary()
        let url = SkillLock.projectURL(folder: locations.root)
        let bytes = Data(#"{"version":1,"skills":{"mine":{"source":"a/b","sourceType":"github"}}}"#.utf8)
        try bytes.write(to: url)
        let flaky = Flaky(2)
        StoreFile.$reader.withValue({ try flaky.read($0) }) {
            #expect(throws: DaemonAPI.CatalogError.self) { try SkillLock.load(.project, at: url) }
        }
        let passing = Flaky(1)
        let lock = try StoreFile.$reader.withValue({ try passing.read($0) }) { try SkillLock.load(.project, at: url) }
        #expect(lock.names == ["mine"])
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func theExcludeFileKeepsThePersonsLines() throws {
        let locations = try temporary()
        let common = locations.root.appendingPathComponent("git")
        let exclude = common.appendingPathComponent("info/exclude")
        try fileManager.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mine = Data("# mine\n*.log\n".utf8) + Data([0xFF, 0x0A])
        try mine.write(to: exclude)

        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: exclude.path)
        #expect(throws: GitWorktrees.Failure.self) { try GitWorktrees.ensureExcluded(commonDir: common) }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: exclude.path)
        #expect(try Data(contentsOf: exclude) == mine)

        try GitWorktrees.ensureExcluded(commonDir: common)
        let after = try Data(contentsOf: exclude)
        #expect(after.starts(with: mine), "every byte of the person's kept")
        #expect(String(decoding: after, as: UTF8.self).contains(GitWorktrees.excludeLine))
        #expect((try fileManager.attributesOfItem(atPath: exclude.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    // MARK: Telling the person

    /// Devices that do not read are said where the windows look, not only in the log:
    /// asked on connecting, and gone once the file reads again (a held project file).
    @Test func theDaemonSaysWhatItCouldNotRead() async throws {
        let locations = try temporary()
        try Data("{\"torn".utf8).write(to: locations.devices)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        _ = DeviceStore(locations: locations).load()
        let notes = await core.storeNotes().notes
        #expect(notes.contains { $0.contains("devices.json could not be read") }, "\(notes)")
    }
}
