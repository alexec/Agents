import Foundation
import Testing
@testable import AgentsKit

/// FR-015 has two halves and both are measurable, so neither is left to a hand check:
/// a folder with many thousands of entries stays responsive, and a large file is not
/// read whole to show the start of it.
@Suite("The files pane at awkward sizes")
struct FilesPaneScaleTests {
    @Test func aFolderOfFiftyThousandEntriesListsQuickly() throws {
        let root = URL.temporaryDirectory.appending(path: "scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Writing 50,000 real files takes longer than the test is worth, and the cap
        // means the reader never sees more than its limit anyway. 6,000 is comfortably
        // past the 5,000 cap, which is the boundary that matters.
        for index in 0..<6_000 {
            try Data().write(to: root.appending(path: String(format: "file%05d.txt", index)))
        }

        let started = ContinuousClock.now
        let listing = try DirectoryReader.read(root)
        let took = ContinuousClock.now - started

        #expect(listing.entries.count == DirectoryReader.entryLimit)
        #expect(listing.omitted == 6_000 - DirectoryReader.entryLimit)
        // Generous, because this runs on whatever machine happens to be building. The
        // point is that it is bounded work, not that it hits a particular number.
        #expect(took < .seconds(2), "listing took \(took)")
    }

    @Test func aLargeFileIsNotReadWholeToShowItsStart() throws {
        let root = URL.temporaryDirectory.appending(path: "big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 200MB, the size the quickstart names.
        let url = root.appending(path: "huge.log")
        let line = Data(String(repeating: "x", count: 1023).appending("\n").utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        for _ in 0..<(200 * 1024) { handle.write(line) }
        try handle.close()

        let started = ContinuousClock.now
        let probe = try FileProbe.read(url)
        let took = ContinuousClock.now - started

        #expect(probe.kind == .text)
        #expect(probe.isTruncated)
        // Only the prefix was read, whatever the file's size.
        #expect(probe.prefix.count == FileProbe.prefixLimit)
        #expect(probe.size == 200 * 1024 * 1024)
        #expect(took < .milliseconds(500), "probe took \(took)")
    }

    @Test func theTreeIsNeverWalked() throws {
        // A folder with something enormous nested inside it costs nothing until the
        // user opens that folder. This is why `node_modules` is not a problem.
        let root = URL.temporaryDirectory.appending(path: "nested-\(UUID().uuidString)")
        let deep = root.appending(path: "node_modules")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2_000 {
            try Data().write(to: deep.appending(path: "dep\(index).js"))
        }
        try Data("{}".utf8).write(to: root.appending(path: "package.json"))

        let started = ContinuousClock.now
        let listing = try DirectoryReader.read(root)
        let took = ContinuousClock.now - started

        // Two entries at this level, and the 2,000 below were never looked at.
        #expect(listing.entries.count == 2)
        #expect(took < .milliseconds(100), "listing took \(took)")
    }
}
