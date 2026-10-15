import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Which daemon a process belongs to.
///
/// The root is the whole of a daemon's identity, so the rule that picks it is the rule
/// that decides whether a second copy of the app is a second daemon or a fight over
/// the first one's lock. It is a pure function for exactly that reason.
@Suite("Which daemon this process belongs to")
struct StoreLocationsTests {
    @Test func withNothingSaidItIsTheOrdinaryPlace() {
        let chosen = StoreLocations.chosen(arguments: ["agentsd"], environment: [:])
        #expect(chosen.root.path == StoreLocations.standard.root.path)
        #expect(chosen.isStandard)
    }

    @Test func anArgumentNamesTheRoot() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root", "/tmp/branch"],
                                           environment: [:])
        #expect(chosen.root.path == "/tmp/branch")
        #expect(!chosen.isStandard)
        #expect(chosen.name == "branch")
    }

    @Test func theEqualsFormIsTheSameArgument() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root=/tmp/branch"],
                                           environment: [:])
        #expect(chosen.root.path == "/tmp/branch")
    }

    @Test func theVariableNamesItToo() {
        let chosen = StoreLocations.chosen(arguments: ["agentsd"],
                                           environment: ["AGENTS_ROOT": "/tmp/branch"])
        #expect(chosen.root.path == "/tmp/branch")
    }

    /// The argument wins because it is the one that survives `open`: macOS passes a
    /// second copy of a bundle its arguments and not its environment.
    @Test func theArgumentBeatsTheVariable() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root", "/tmp/asked"],
                                           environment: ["AGENTS_ROOT": "/tmp/inherited"])
        #expect(chosen.root.path == "/tmp/asked")
    }

    /// An empty value is somebody's mistake, not a request for the current directory.
    @Test func anEmptyRootIsIgnored() {
        #expect(StoreLocations.chosen(arguments: ["Agents", "--root", ""], environment: [:])
            .root.path == StoreLocations.standard.root.path)
        #expect(StoreLocations.chosen(arguments: ["agentsd"], environment: ["AGENTS_ROOT": ""])
            .root.path == StoreLocations.standard.root.path)
    }

    @Test func aTildeIsAHomeDirectory() {
        let chosen = StoreLocations.chosen(arguments: ["Agents", "--root", "~/Agents-branch"],
                                           environment: [:])
        #expect(chosen.root.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(chosen.name == "Agents-branch")
    }

    /// Everything that makes a daemon a daemon hangs off the root, which is why two
    /// roots cannot collide over a lock, a socket, or an agent's record.
    @Test func twoRootsShareNothing() {
        let one = StoreLocations(root: URL(filePath: "/tmp/one"))
        let two = StoreLocations(root: URL(filePath: "/tmp/two"))
        #expect(one.socket.path != two.socket.path)
        #expect(one.lock.path != two.lock.path)
        #expect(one.log.path != two.log.path)
        #expect(one.agents.path != two.agents.path)
        #expect(one.projects.path != two.projects.path)
    }

    // MARK: Caches and logs (#1030)

    @Test func theOrdinaryRootsCachesAndLogsAreThePlatformsFolders() {
        let (cache, logs) = StoreLocations.platformFolders(root: StoreLocations.standardRoot, environment: [:])
        #if canImport(Darwin)
        #expect(cache.path.hasSuffix("Library/Caches/com.alexecollins.agents"))
        #expect(logs.path.hasSuffix("Library/Logs/Agents"))
        #else
        #expect(cache.path.hasSuffix(".cache/agents"))
        #expect(logs.path.hasSuffix(".local/state/agents/logs"))
        #endif
    }

    @Test func anotherRootHasAFolderOfItsOwnInEach() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let one = StoreLocations.platformFolders(root: home.appending(path: "branch/one"), environment: [:])
        let two = StoreLocations.platformFolders(root: home.appending(path: "other/one"), environment: [:])
        let ordinary = StoreLocations.platformFolders(root: StoreLocations.standardRoot, environment: [:])
        #expect(one.cache.deletingLastPathComponent().deletingLastPathComponent() == ordinary.cache)
        #expect(one.cache.lastPathComponent.hasPrefix("one-"))
        #expect(one.cache != two.cache, "two roots with one name share nothing")
        #expect(one.logs != two.logs)
    }

    #if !canImport(Darwin)
    @Test func linuxFollowsTheXDGVariables() {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "srv/root")
        let (cache, logs) = StoreLocations.platformFolders(
            root: root, environment: ["XDG_CACHE_HOME": "/c", "XDG_STATE_HOME": "/s"])
        #expect(cache.path.hasPrefix("/c/agents/roots/root-"))
        #expect(logs.path.hasPrefix("/s/agents/logs/roots/root-"))
    }
    #endif

    /// A test's root, or a walk's `/tmp/run-<slug>`, keeps its caches and logs inside
    /// itself, so removing it leaves nothing in the person's folders.
    @Test func aRootInTheTemporaryFolderKeepsThemInside() {
        let root = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        #expect(locations.cacheRoot == root.appending(path: "cache", directoryHint: .isDirectory))
        #expect(locations.logRoot == root.appending(path: "logs", directoryHint: .isDirectory))
        #expect(StoreLocations.isTemporary(URL(fileURLWithPath: "/tmp/run-walk")))
        #expect(locations.log.deletingLastPathComponent() == locations.logRoot)
        #expect(locations.tools.deletingLastPathComponent() == locations.cacheRoot)
        #expect(locations.archiveIndex.deletingLastPathComponent() == locations.cacheRoot)
        #expect(locations.optionCache.deletingLastPathComponent() == locations.cacheRoot)
    }

    /// Delete the cache folder and start again: the daemon starts and the turns come back
    /// from the transcript (#1030).
    @Test func aDeletedCacheIsBuiltAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let id = UUID()
        let entries = [TranscriptEntry(kind: .userMessage("One")), TranscriptEntry(kind: .agentMessage(messageID: nil, text: "a")),
                       TranscriptEntry(kind: .userMessage("Two"))]
        let store = try AgentStore(locations: locations)
        try await store.appendAll(entries, for: id)
        _ = try await store.turns(for: id)
        #expect(FileManager.default.fileExists(atPath: locations.turns(id).path))
        try FileManager.default.removeItem(at: locations.cacheRoot)

        let daemon = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await daemon.shutDown()
        let page = try await AgentStore(locations: locations).turns(for: id)
        #expect(page.turns.map { $0.ask?.text } == ["One"])
    }
}
