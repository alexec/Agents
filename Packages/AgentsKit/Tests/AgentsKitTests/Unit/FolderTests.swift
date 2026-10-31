import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A folder is its folder, so everything here is about one folder being one folder
/// however it was written down, and about not losing what a newer build wrote.
@Suite("The folder record")
struct FolderTests {
    private func sandbox() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "FolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    @Test func aTrailingSlashIsTheSameFolder() throws {
        let root = try sandbox()
        let withSlash = URL(filePath: root.path + "/")
        #expect(Folder(folder: root).folder == Folder(folder: withSlash).folder)
        // Same folder and same addedAt is the same record: the trailing slash must not
        // be the thing that makes them differ.
        let when = Date(timeIntervalSince1970: 1_758_000_000)
        #expect(Folder(folder: root, addedAt: when) == Folder(folder: withSlash, addedAt: when))
    }

    @Test func dotDotIsResolvedAway() throws {
        let root = try sandbox()
        let inner = root.appending(path: "inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let roundabout = URL(filePath: inner.path + "/../inner")
        #expect(Folder(folder: roundabout).folder == Folder(folder: inner).folder)
    }

    @Test func aSymlinkIsTheSameFolderAsItsTarget() throws {
        let root = try sandbox()
        let real = root.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(Folder(folder: link).folder == Folder(folder: real).folder)
    }

    @Test func theFolderIsTheIdentity() throws {
        let root = try sandbox()
        let folder = Folder(folder: root)
        #expect(folder.id == folder.folder)
    }

    @Test func archivedAtDecidesArchived() throws {
        let root = try sandbox()
        #expect(!Folder(folder: root).isArchived)
        #expect(Folder(folder: root, archivedAt: Date()).isArchived)
    }

    @Test func unknownFieldsSurviveARoundTrip() throws {
        let root = try sandbox()
        let json = """
        {"folder":"file://\(root.path)","addedAt":"2026-09-18T10:00:00.000Z",\
        "somethingNewerWrote":{"kept":true}}
        """
        let decoded = try StoreCoding.decoder.decode(Folder.self, from: Data(json.utf8))
        #expect(decoded.unknownFields["somethingNewerWrote"] != nil)

        let reencoded = try StoreCoding.encoder.encode(decoded)
        let text = String(decoding: reencoded, as: UTF8.self)
        #expect(text.contains("somethingNewerWrote"))
        #expect(text.contains("kept"))
    }

    @Test func aLiveFolderWritesNoArchivedAt() throws {
        let root = try sandbox()
        let text = String(decoding: try StoreCoding.encoder.encode(Folder(folder: root)),
                          as: UTF8.self)
        #expect(!text.contains("archivedAt"))
    }
}
