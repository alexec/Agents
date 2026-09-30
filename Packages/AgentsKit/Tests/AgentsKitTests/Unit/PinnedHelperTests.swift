import Foundation
import Testing
@testable import AgentsKit

/// The helper runtimes start is the daemon's own binary, copied into the root, so a
/// rebuild of the app cannot make every agent's helper a stranger.
@Suite("The pinned helper")
struct PinnedHelperTests {
    /// A file's contents stand in for its code directory hash.
    private static func identity(_ url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func scratch() throws -> (binary: URL, folder: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let binary = base.appendingPathComponent("agentsd")
        try "build-a".write(to: binary, atomically: true, encoding: .utf8)
        return (binary, base.appendingPathComponent("helpers"))
    }

    @Test func aCopyNamedByItsContentsIsWhatRuntimesStart() throws {
        let (binary, folder) = try Self.scratch()
        let pinned = try #require(PinnedHelper.pin(binary, in: folder, identity: Self.identity,
                                                   runningMatchesDisk: { true }))
        #expect(pinned.lastPathComponent == "agentsd-build-a")
        #expect(Self.identity(pinned) == "build-a")
    }

    /// The whole point: a build writing over the app leaves the copy as it was.
    @Test func aRebuildDoesNotTouchThePinnedCopy() throws {
        let (binary, folder) = try Self.scratch()
        let pinned = try #require(PinnedHelper.pin(binary, in: folder, identity: Self.identity,
                                                   runningMatchesDisk: { true }))
        try "build-b".write(to: binary, atomically: true, encoding: .utf8)
        #expect(Self.identity(pinned) == "build-a")
    }

    /// A daemon started after the file was already rebuilt has nothing true to copy.
    @Test func nothingIsPinnedWhenTheFileIsNoLongerWhatRuns() throws {
        let (binary, folder) = try Self.scratch()
        #expect(PinnedHelper.pin(binary, in: folder, identity: Self.identity, runningMatchesDisk: { false }) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("agentsd-build-a").path))
    }

    /// An unsigned file has no identity, and so no copy.
    @Test func nothingIsPinnedForAnUnsignedFile() throws {
        let (binary, folder) = try Self.scratch()
        #expect(PinnedHelper.pin(binary, in: folder, identity: { _ in nil }, runningMatchesDisk: { true }) == nil)
    }

    /// The same build again reuses its copy; another build's is kept for a week, as its
    /// runtimes may still be starting helpers from it.
    @Test func otherBuildsCopiesGoAfterAWeek() throws {
        let (binary, folder) = try Self.scratch()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let first = try #require(PinnedHelper.pin(binary, in: folder, identity: Self.identity,
                                                  runningMatchesDisk: { true }, now: start))
        try "build-b".write(to: binary, atomically: true, encoding: .utf8)
        let second = try #require(PinnedHelper.pin(binary, in: folder, identity: Self.identity,
                                                   runningMatchesDisk: { true }, now: start.addingTimeInterval(60)))
        #expect(FileManager.default.fileExists(atPath: first.path))
        _ = PinnedHelper.pin(binary, in: folder, identity: Self.identity, runningMatchesDisk: { true },
                             now: start.addingTimeInterval(PinnedHelper.keepOthersFor + 120))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
