import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What one file-change wake in a project costs (#216).
///
/// #173 made the project's watch hold; each wake still read every pin, a device's watch
/// left nothing out and named every folder, a mention walk ran per keystroke, and a big folder was stat-ed whole. Each
/// test here pins one of those down by counting the work, not by timing it.
@Suite("What a wake costs", .timeLimit(.minutes(1)))
struct WakeCostTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWakeCost-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work.resolvingSymlinksInPath()))
    }

    private func core(_ locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: FakeLauncher(script: FakeACPAgent.Script()))
    }

    // MARK: 1. A batch reads the pins once per change of theirs

    @Test func aBatchOutsideAgentsReadsNoPins() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        try await core.writePins(PinsFile(pins: [PinEntry(path: "docs/a.md", pinnedBy: Pinner(person: true))]), in: work)
        let source = work.appending(path: "Sources")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        // The first batch fills what is held.
        await core.projectFilesChanged([source], in: work)
        let pins = await core.pinsReads
        for _ in 0..<20 { await core.projectFilesChanged([source], in: work) }
        #expect(await core.pinsReads == pins, "an edit in Sources read pins.json again")

        // The pins file changing by hand (a pull) is read once, by the batch that names `.agents`.
        let file = DaemonCore.pinsFileURL(work)
        try PinsFile(pins: [PinEntry(path: "docs/b.md", pinnedBy: Pinner(person: true))]).fileData().write(to: file)
        await core.projectFilesChanged([work.appending(path: ".agents")], in: work)
        #expect(await core.pagePaths(work).contains("docs/b.md"))
        #expect(await core.pinsReads == pins + 1)
    }

    @Test func thePinsFileIsReadAgainWhenItChangesEvenUnheard() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        try await core.writePins(PinsFile(pins: [PinEntry(path: "a.md", pinnedBy: Pinner(person: true))]), in: work)
        #expect(await core.readPins(work).pins.map(\.path) == ["a.md"])
        // Written beside the daemon with no watch to say so: its stamp moved, so it is read.
        try PinsFile(pins: [PinEntry(path: "b.md", pinnedBy: Pinner(person: true))]).fileData()
            .write(to: DaemonCore.pinsFileURL(work))
        #expect(await core.readPins(work).pins.map(\.path) == ["b.md"])
    }

    // MARK: 2. A device's watch leaves out what the project's does, and names at most 64

    actor Sent {
        var notes: [DaemonAPI.FilesChangedNotification] = []
        func record(_ note: DaemonAPI.FilesChangedNotification) { notes.append(note) }
    }

    @Test func aDevicesWatchLeavesOutBuildOutputAndSaysManyPastTheLimit() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        let sent = Sent()
        let phone = UUID()
        await core.setBroadcaster { _, _ in }
        await core.setAddressedBroadcaster { method, params, wanted in
            guard method == DaemonAPI.Notification.filesChanged, wanted(.init(id: phone, surface: .device(phone))),
                  let note = try? params?.decode(DaemonAPI.FilesChangedNotification.self) else { return }
            Task { await sent.record(note) }
        }
        for folder in ["node_modules/pkg", ".build/debug", "Lib/.build/debug", "build/out"] {
            try FileManager.default.createDirectory(at: work.appending(path: folder), withIntermediateDirectories: true)
        }
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await core.watchFiles(.init(agentID: id, folder: work.path), connection: phone)
        let excluded = Set(await core.fileWatchExclusions[work]?.map(\.path) ?? [])
        for folder in [".agents/worktrees", "node_modules", ".build", "Lib/.build", "build"] {
            #expect(excluded.contains(work.appending(path: folder).standardizedFileURL.path), "\(folder) is watched")
        }

        // Somebody opens build/out on the phone: that folder is watched after all.
        try await core.watchFiles(.init(agentID: id, folder: work.appending(path: "build/out").path), connection: phone)
        let opened = await core.fileWatchExclusions[work]?.map(\.lastPathComponent) ?? []
        #expect(!opened.contains("build"))
        #expect(opened.contains("node_modules"))

        let many = (0..<100).map { work.appending(path: "src/f\($0)") }
        await core.filesChanged(under: work, folders: many)
        await core.filesChanged(under: work, folders: Array(many.prefix(3)))
        let notes = await eventuallySome("two notices") { await sent.notes.count >= 2 ? await sent.notes : nil } ?? []
        #expect(notes.first?.folders.count == DaemonAPI.FilesChangedNotification.folderLimit)
        #expect(notes.first?.many == true)
        #expect(notes.last?.folders.count == 3)
        #expect(notes.last?.many == nil)
    }

    @Test func aNoticeWithoutManyStillDecodesAndOneWithItSaysSo() throws {
        let old = try JSONDecoder().decode(DaemonAPI.FilesChangedNotification.self,
                                           from: Data(#"{"agentID":"\#(UUID().uuidString)","folders":["/w"]}"#.utf8))
        #expect(old.many == nil)
        let quiet = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]
        #expect(quiet?["many"] == nil, "a few folders say nothing of many")
    }

    @Test @MainActor func theRemoteReadsEveryShownFolderAgainOnMany() async throws {
        final class Silent: DaemonLink, @unchecked Sendable {
            func transport() async throws -> any LineTransport {
                let (near, far) = PairedTransport.pair()
                _ = Task {
                    for try await line in far.lines() {
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                              let id = object["id"] as? Int else { continue }
                        try? far.write(line: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
                    }
                }
                return near
            }
        }
        let client = DaemonClient(link: Silent())
        try await client.connect(startIfNeeded: false)
        let files = RemoteFiles(client: client, patience: .seconds(2))
        let agent = UUID(), other = UUID()
        let shown = [URL(filePath: "/w/src"), URL(filePath: "/w/docs")]
        for folder in shown { await files.watch(agentID: agent, folder: folder) }
        await files.watch(agentID: other, folder: URL(filePath: "/w/src"))
        files.apply(DaemonAPI.FilesChangedNotification(agentID: agent, folders: ["/w/elsewhere"], many: true))
        for folder in shown { #expect(files.changeCount(agentID: agent, folder: folder) == 1) }
        #expect(files.changeCount(agentID: other, folder: URL(filePath: "/w/src")) == 0)
    }

    // MARK: 3. One mention walk in flight per agent

    final class Walks: @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var most = 0
        private(set) var cancelled = 0
        func began() { lock.withLock { running += 1; most = max(most, running) } }
        func ended(cancelled wasCancelled: Bool) { lock.withLock { running -= 1; if wasCancelled { cancelled += 1 } } }
    }

    @Test func eachKeystrokesWalkReplacesTheLast() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        let walks = Walks()
        await core.setMentionWalker { term, _ in
            walks.began()
            // A walk that only a cancel or the last keystroke ends.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !Task.isCancelled, term != "abcd", ContinuousClock.now < deadline { usleep(2_000) }
            walks.ended(cancelled: Task.isCancelled)
            return Task.isCancelled ? [] : [FileMention(url: URL(filePath: "/w/\(term)"), relativePath: term)]
        }
        var answers: [Task<[DaemonAPI.FileMentionDTO], Error>] = []
        for term in ["a", "ab", "abc"] {
            answers.append(Task { try await core.fileMentions(.init(agentID: id, term: term)) })
            try await Task.sleep(for: .milliseconds(50))
        }
        let last = try await core.fileMentions(.init(agentID: id, term: "abcd"))
        #expect(last.map(\.relativePath) == ["abcd"])
        for answer in answers { #expect(try await answer.value.isEmpty, "a superseded walk answered") }
        #expect(walks.most <= 2, "walks overlapped beyond the one being cancelled")
        #expect(walks.cancelled == 3)
        #expect(await core.mentionWalks.isEmpty)
    }

    // MARK: 4. A big folder is stat-ed to twice the limit, off the actor

    @Test func onlyTwiceTheLimitIsStatted() throws {
        let names = (0..<100).map { String(format: "N%03d", 99 - $0) }
        #expect(DirectoryReader.candidates(names, limit: 60) == names)
        let picked = DirectoryReader.candidates(names, limit: 10)
        #expect(picked == (0..<20).map { String(format: "N%03d", $0) })

        let root = URL.temporaryDirectory.appending(path: "reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<50 { try Data().write(to: root.appending(path: String(format: "f%02d", index))) }
        try FileManager.default.createDirectory(at: root.appending(path: "a-folder"), withIntermediateDirectories: true)
        let listing = try DirectoryReader.read(root, limit: 10)
        #expect(listing.entries.count == 10)
        #expect(listing.omitted == 41)
        #expect(listing.entries.first?.name == "a-folder")
        #expect(listing.entries.first?.isDirectory == true)
    }

    // MARK: 5. Every exclusion counts, and the list follows the top level

    @Test func aNinthExclusionAndGitsOwnWritesAreDroppedBeforeTheActor() throws {
        let root = URL(filePath: "/p")
        let excluded = [".agents/worktrees", ".git/objects", "A/.build", "B/.build", "C/.build", "D/.build",
                        "E/.build", "F/.build", "G/.build", "H/.build"].map { root.appending(path: $0) }
        let filter = DaemonCore.WatchFilter(root: root, excluded: excluded, gitNoise: true)
        let kept = filter.kept(["H/.build/debug", "G/.build", "Sources", ".git", ".git/logs/refs/heads",
                                ".git/refs/heads/agents", ".git/worktrees/lane", ".git/worktrees/lane/logs", ".git/refs/remotes/origin"]
                                .map { root.appending(path: $0) })
        #expect(kept.map(\.path) == ["/p/Sources", "/p/.git", "/p/.git/refs/heads/agents", "/p/.git/worktrees/lane"])
        // A device's watch keeps git's folders: somebody may be looking in one.
        let device = DaemonCore.WatchFilter(root: root, excluded: excluded, gitNoise: false)
        #expect(device.kept([root.appending(path: ".git/logs")]).count == 1)
    }

    @Test func theExclusionsAreAllOfThemNotTheFirstEight() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        for package in ["A", "B", "C", "D", "E", "F", "G"] {
            try FileManager.default.createDirectory(at: work.appending(path: "\(package)/.build"),
                                                    withIntermediateDirectories: true)
        }
        let excluded = await core.projectWatchExclusions(work).map { String($0.path.dropFirst(work.path.count + 1)) }
        #expect(excluded.count > FolderWatch.maximumExclusions)
        #expect(Array(excluded.prefix(2)) == [".agents/worktrees", ".git/objects"])
        #expect(excluded.contains("G/.build"))
    }

    @Test func aBuildFolderMadeLaterIsLeftOutWithinTheSecond() async throws {
        let (locations, work) = try temporary()
        let core = try core(locations)
        try FileManager.default.createDirectory(at: work.appending(path: "Lib/Sources"), withIntermediateDirectories: true)
        await core.watchProject(work)
        let checks = await core.exclusionChecks
        // An edit in Lib: a look, and nothing new to leave out.
        await core.projectFilesChanged([work.appending(path: "Lib/Sources"), work.appending(path: "Lib")], in: work)
        await eventually("the look ran") { await core.exclusionChecks > checks }
        let before = await core.projectWatchExclusions[work] ?? []

        try FileManager.default.createDirectory(at: work.appending(path: "Lib/.build/debug"), withIntermediateDirectories: true)
        // Many batches in the second: one look.
        for _ in 0..<10 { await core.projectFilesChanged([work.appending(path: "Lib")], in: work) }
        await eventually("Lib/.build is left out") {
            await core.projectWatchExclusions[work]?.contains { $0.path.hasSuffix("/Lib/.build") } == true
        }
        // The watch's own reports of those folders may add a look; never one per batch.
        #expect(await core.exclusionChecks <= checks + 3)
        #expect((await core.projectWatchExclusions[work] ?? []).count == before.count + 1)
        await core.stopWatchingAllWorkflows()
    }
}
