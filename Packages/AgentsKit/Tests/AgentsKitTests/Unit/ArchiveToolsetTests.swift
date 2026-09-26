import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A runtime the vendor ships as a signed archive, installed on this Mac (049).
@Suite("A vendor archive toolset", .timeLimit(.minutes(1)))
struct ArchiveToolsetTests {
    static let bundled = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/toolsets", isDirectory: true)

    // MARK: The manifest the app carries

    @Test func theBundledAntigravityArchiveIsPinnedFromGoogleForEveryPlatform() throws {
        let toolset = try ArchiveToolset.load(from: Self.bundled.appendingPathComponent("antigravity"))
        #expect(toolset.manifest.runtimeID == "antigravity")
        #expect(toolset.manifest.kind == "archive")
        #expect(toolset.id.count == 16)
        #expect(Set(toolset.manifest.platforms.keys)
                == ["darwin-aarch64", "darwin-x86_64", "linux-x86_64", "linux-aarch64"])
        for (name, platform) in toolset.manifest.platforms {
            #expect(platform.url.absoluteString.hasPrefix("https://dl.google.com/"), "\(name)")
            #expect(platform.sha256.count == 64 && platform.sha256.allSatisfy(\.isHexDigit), "\(name)")
            #expect(platform.size > 50_000_000, "\(name)")
            #expect(platform.command == "agy_acp_server.par", "\(name)")
            #expect(platform.arguments == (name.hasPrefix("linux-") ? ["--uid="] : []), "\(name)")
        }
        // Measured by hand on 2026-09-25 (research R2).
        #expect(toolset.manifest.platforms["darwin-aarch64"]?.sha256
                == "0fab9938812e6b32b3b543e65e4f3a0025ceef755413db13542d9a9b81ea803c")
    }

    /// Each loader takes only its own kind, so the two can read one `toolsets/` folder.
    @Test func archivesAndNodeToolsetsAreToldApart() {
        let archives = ArchiveToolset.loadAll(from: Self.bundled)
        let node = Toolset.loadAll(from: Self.bundled)
        #expect(archives.keys.sorted() == ["antigravity"])
        #expect(node["antigravity"] == nil)
        #expect(node["claude"] != nil)
    }

    @Test func anyChangeToTheManifestIsANewToolset() {
        let one = ArchiveToolset.id(manifest: Data(#"{"a":1}"#.utf8))
        #expect(one == ArchiveToolset.id(manifest: Data(#"{"a":1}"#.utf8)))
        #expect(one != ArchiveToolset.id(manifest: Data(#"{"a":2}"#.utf8)))
    }

    @Test func theShimRunsTheCommandWithItsPlatformsArgumentsAndPassesTheRestOn() throws {
        let toolset = try ArchiveToolset.load(from: Self.bundled.appendingPathComponent("antigravity"))
        let linux = try #require(toolset.manifest.platforms["linux-x86_64"])
        let lines = toolset.shimLines(for: linux)
        #expect(lines.last == #"exec "$d/agy_acp_server.par" "--uid=" "$@""#)
        #expect(!lines.contains { $0.contains("'") }, "a server's script hands them to printf quoted")
        #expect(toolset.shimName == "agy_acp_server")
    }

    @Test func platformsAreNamedAsTheRegistryNamesThem() {
        #expect(ArchiveToolset.linuxPlatform(.x86_64) == "linux-x86_64")
        #expect(ArchiveToolset.linuxPlatform(.aarch64) == "linux-aarch64")
        #expect(ArchiveToolset.linuxPlatform(.other("riscv64")) == nil)
        #expect(ArchiveToolset.macPlatform.hasPrefix("darwin-"))
        #expect(ArchiveToolset.megabytes(111_725_488) == "112 MB")
    }

    // MARK: Installing it

    @Test func aWholeInstallIsCurrentMarkedOkAndDiscoveryFindsIt() async throws {
        let fake = try FakeArchive()
        defer { fake.remove() }
        let shim = try await fake.installer().install()

        let folder = fake.tools.appendingPathComponent("antigravity")
        let current = folder.appendingPathComponent("current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == fake.toolset.id)
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("ok").path))
        #expect(!FileManager.default.fileExists(atPath: current.appendingPathComponent("archive.zip").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == [fake.toolset.id, "current"].sorted(), "nothing half-built is left beside it")

        // The shim runs the unpacked program with the platform's arguments and its own.
        let output = try FakeArchive.run(shim, ["--hello"])
        #expect(output == "fake server --uid= --hello\n")

        var discovery = RuntimeDiscovery(searchPaths: ["/nowhere"])
        discovery.macToolsHome = fake.tools.path
        #expect(discovery.locate(RuntimeCatalog.antigravity)
                == .available(path: "\(current.path)/bin/agy_acp_server", supportsResume: false))
    }

    @Test func aDownloadThatDoesNotMatchLeavesNothingBehind() async throws {
        let fake = try FakeArchive(wrongChecksum: true)
        defer { fake.remove() }
        await #expect(throws: MacToolsetInstaller.Failure.checksum) { try await fake.installer().install() }
        let folder = fake.tools.appendingPathComponent("antigravity")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == [])
    }

    @Test func aMissingDownloadSaysSo() async throws {
        let fake = try FakeArchive()
        defer { fake.remove() }
        try FileManager.default.removeItem(at: fake.archive)
        do {
            try await fake.installer().install()
            Issue.record("installed from nothing")
        } catch let failure as MacToolsetInstaller.Failure {
            #expect(failure.sentence(for: "Antigravity").hasPrefix("Couldn’t download Antigravity"))
        }
    }

    @Test func tooLittleRoomIsRefusedBeforeAnythingIsFetched() async throws {
        let fake = try FakeArchive()
        defer { fake.remove() }
        await #expect(throws: MacToolsetInstaller.Failure.needsRoom(fake.toolset.manifest.minFreeBytes)) {
            try await fake.installer(freeBytes: 10).install()
        }
        #expect(MacToolsetInstaller.Failure.needsRoom(1_500_000_000).sentence(for: "Antigravity")
                == "Not enough room: Antigravity needs about 1.5 GB free.")
    }

    @Test func aPlatformKnownNotToWorkIsNotInstalledOrOffered() async throws {
        let fake = try FakeArchive(knownBroken: "Google’s build crashes at start on this Mac.")
        defer { fake.remove() }
        await #expect(throws: MacToolsetInstaller.Failure.unavailable("Google’s build crashes at start on this Mac.")) {
            try await fake.installer().install()
        }
        let installer = RuntimeInstaller(discovery: RuntimeDiscovery(searchPaths: ["/nowhere"]),
                                         archives: ["antigravity": fake.installer()])
        #expect(installer.recipe(for: RuntimeCatalog.antigravity) == nil, "the page, not a button that can only fail")
        let working = try FakeArchive()
        defer { working.remove() }
        let offered = RuntimeInstaller(discovery: RuntimeDiscovery(searchPaths: ["/nowhere"]),
                                       archives: ["antigravity": working.installer()])
        #expect(offered.recipe(for: RuntimeCatalog.antigravity) == .toolset(runtimeID: "antigravity"))
    }

    @Test func aLeftoverHalfBuildIsReplaced() async throws {
        let fake = try FakeArchive()
        defer { fake.remove() }
        let part = fake.tools.appendingPathComponent("antigravity/.part-\(fake.toolset.id)")
        try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: part.appendingPathComponent("junk"))
        try await fake.installer().install()
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func theDaemonsInstallerUsesItAndSaysTheRuntimesName() async throws {
        let fake = try FakeArchive()
        defer { fake.remove() }
        var discovery = RuntimeDiscovery(searchPaths: ["/nowhere"])
        discovery.macToolsHome = fake.tools.path
        let installer = RuntimeInstaller(discovery: discovery, archives: ["antigravity": fake.installer()])
        let steps = Steps()
        let result = await installer.install(RuntimeCatalog.antigravity) { steps.add($0) }
        #expect(result.isAvailable)
        #expect(steps.all.first?.hasPrefix("Downloading Antigravity (") == true)
        #expect(steps.all.contains("Unpacking Antigravity"))
    }
}

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [String] = []
    func add(_ step: String) { lock.lock(); steps.append(step); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return steps }
}

/// An archive small enough to install in a test: a zip holding a shell script called
/// `agy_acp_server.par`, served from a `file://` URL, with its real SHA-256 or a wrong one.
struct FakeArchive {
    let toolset: ArchiveToolset
    let root: URL
    let archive: URL
    static let platform = "darwin-aarch64"

    init(wrongChecksum: Bool = false, knownBroken: String? = nil) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("archive-toolset-\(UUID().uuidString)", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let bundle = root.appendingPathComponent("toolset", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FakeMacToolset.script(at: staging.appendingPathComponent("agy_acp_server.par"),
                                  #"#!/bin/sh"# + "\n" + #"echo "fake server $*""#)
        archive = root.appendingPathComponent("server.zip")
        _ = try Self.run("/usr/bin/ditto", ["-c", "-k", staging.path, archive.path])
        let sha = wrongChecksum ? String(repeating: "0", count: 64) : try MacToolsetInstaller.sha256(of: archive)
        let size = (try fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? 0
        let manifest = ArchiveToolset.Manifest(
            runtimeID: "antigravity", version: "0.0.0-fake", source: "test", minFreeBytes: 1024,
            platforms: [Self.platform: .init(url: archive, sha256: sha, size: size, command: "agy_acp_server.par",
                                             arguments: ["--uid="], knownBroken: knownBroken)])
        try JSONEncoder().encode(manifest).write(to: bundle.appendingPathComponent(Toolset.manifestFile))
        toolset = try ArchiveToolset.load(from: bundle)
    }

    var tools: URL { root.appendingPathComponent("tools", isDirectory: true) }

    func installer(freeBytes: Int64? = nil) -> MacArchiveInstaller {
        MacArchiveInstaller(toolset: toolset, tools: tools, platform: Self.platform,
                            environment: ["PATH": "/usr/bin:/bin"], freeBytes: { _ in freeBytes })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.environment = ["COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return String(decoding: data, as: UTF8.self)
    }
}
