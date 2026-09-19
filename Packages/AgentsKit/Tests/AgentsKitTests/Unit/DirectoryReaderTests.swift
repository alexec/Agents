import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Reading one level of a folder")
struct DirectoryReaderTests {
    private func makeFolder(files: [String] = [], directories: [String] = []) throws -> URL {
        let root = URL.temporaryDirectory.appending(path: "dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in directories {
            try FileManager.default.createDirectory(at: root.appending(path: name),
                                                    withIntermediateDirectories: true)
        }
        for name in files {
            try Data("x".utf8).write(to: root.appending(path: name))
        }
        return root
    }

    @Test func directoriesComeFirstThenFilesEachByNameIgnoringCase() throws {
        let root = try makeFolder(files: ["beta.txt", "Alpha.txt", "gamma.txt"],
                                  directories: ["Zed", "apples"])
        let listing = try DirectoryReader.read(root)
        #expect(listing.entries.map(\.name) == ["apples", "Zed", "Alpha.txt", "beta.txt", "gamma.txt"])
        let firstTwoAreDirectories = listing.entries.prefix(2).allSatisfy(\.isDirectory)
        #expect(firstTwoAreDirectories)
    }

    @Test func aDirectoryHasNoSizeAndAFileDoes() throws {
        let root = try makeFolder(files: ["one.txt"], directories: ["sub"])
        let listing = try DirectoryReader.read(root)
        let directory = try #require(listing.entries.first { $0.isDirectory })
        let file = try #require(listing.entries.first { !$0.isDirectory })
        #expect(directory.size == nil)
        #expect(file.size == 1)
    }

    @Test func theCapSaysHowManyItLeftOut() throws {
        let names = (0..<30).map { String(format: "file%03d.txt", $0) }
        let root = try makeFolder(files: names)
        let listing = try DirectoryReader.read(root, limit: 10)
        #expect(listing.entries.count == 10)
        #expect(listing.omitted == 20)
        #expect(listing.isTruncated)
        // The cap takes the front of the sorted list, so it is the same ten every time
        // rather than whatever the file system happened to hand back.
        #expect(listing.entries.first?.name == "file000.txt")
    }

    @Test func awholeDirectoryIsNotTruncated() throws {
        let root = try makeFolder(files: ["a.txt", "b.txt"])
        let listing = try DirectoryReader.read(root)
        #expect(listing.omitted == 0)
        #expect(listing.isTruncated == false)
    }

    @Test func aDirectoryThatIsNotThereSaysSo() throws {
        let missing = URL.temporaryDirectory.appending(path: "gone-\(UUID().uuidString)")
        #expect(throws: DirectoryReader.Failure.gone) { try DirectoryReader.read(missing) }
    }

    @Test func aFileIsNotADirectory() throws {
        let root = try makeFolder(files: ["one.txt"])
        #expect(throws: DirectoryReader.Failure.notADirectory) {
            try DirectoryReader.read(root.appending(path: "one.txt"))
        }
    }

    @Test func anEntryThatVanishesMidListingDoesNotFailTheListing() throws {
        // The pane is reading a folder an agent is writing to, so entries disappear
        // under it. One that has gone is absent from the answer, not an error for the
        // whole directory.
        let root = try makeFolder(files: ["keep.txt", "vanishes.txt"])
        try FileManager.default.removeItem(at: root.appending(path: "vanishes.txt"))
        let listing = try DirectoryReader.read(root)
        #expect(listing.entries.map(\.name) == ["keep.txt"])
    }
}
