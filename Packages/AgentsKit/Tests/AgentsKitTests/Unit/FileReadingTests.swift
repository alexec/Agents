import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("A file as carried to a device")
struct FileReadingTests {
    private func write(_ data: Data, named name: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    private func roundTrip(_ reading: FileReading) throws -> FileReading {
        try JSONDecoder().decode(FileReading.self, from: JSONEncoder().encode(reading))
    }

    @Test func textIsCarriedWhole() throws {
        let url = try write(Data("# Plan\n\nFirst.\n".utf8), named: "plan.md")
        guard case .text(let text, let isTruncated, let size, _) = try FileReading.read(url) else {
            Issue.record("not text"); return
        }
        #expect(text == "# Plan\n\nFirst.\n")
        #expect(!isTruncated)
        #expect(size == 15)
    }

    @Test func aLongTextIsCutAndSaysSo() throws {
        let url = try write(Data(repeating: UInt8(ascii: "a"), count: FileProbe.prefixLimit + 10), named: "big.log")
        guard case .text(let text, let isTruncated, let size, _) = try FileReading.read(url) else {
            Issue.record("not text"); return
        }
        #expect(text.utf8.count == FileProbe.prefixLimit)
        #expect(isTruncated)
        #expect(size == FileProbe.prefixLimit + 10)
        #expect(FileReading.truncationNote(shown: text.utf8.count, of: size).hasPrefix("Showing the first "))
    }

    @Test func aPictureIsCarriedAsBytes() throws {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#.utf8)
        let url = try write(svg, named: "diagram.svg")
        guard case .image(let bytes, let describedAs, _) = try FileReading.read(url) else {
            Issue.record("not an image"); return
        }
        #expect(bytes == svg)
        #expect(describedAs.hasPrefix("SVG image"))
    }

    @Test func aPictureTooBigToCarryIsDescribed() throws {
        let url = try write(Data(count: FileReading.imageLimit + 1), named: "photo.jpg")
        guard case .other(let describedAs, let size, _) = try FileReading.read(url) else {
            Issue.record("not described"); return
        }
        #expect(describedAs.hasPrefix("JPEG image"))
        #expect(size == FileReading.imageLimit + 1)
    }

    @Test func binaryIsDescribed() throws {
        let url = try write(Data([0x53, 0x51, 0x00, 0x01]), named: "store.sqlite")
        guard case .other(let describedAs, _, _) = try FileReading.read(url) else {
            Issue.record("not described"); return
        }
        #expect(describedAs.hasPrefix("SQLite database"))
    }

    @Test func aKnownStampIsAnsweredUnchanged() throws {
        let url = try write(Data("same".utf8), named: "a.txt")
        let first = try FileReading.read(url)
        #expect(try FileReading.read(url, known: first.stamp) == .unchanged(first.stamp))
    }

    @Test func aChangedFileIsReadAgainDespiteAStamp() throws {
        let url = try write(Data("one".utf8), named: "a.txt")
        let first = try FileReading.read(url)
        try Data("three".utf8).write(to: url)
        guard case .text(let text, _, _, _) = try FileReading.read(url, known: first.stamp) else {
            Issue.record("not re-read"); return
        }
        #expect(text == "three")
    }

    @Test func goneAndFolderAreErrorsNotContent() throws {
        let url = try write(Data("x".utf8), named: "a.txt")
        #expect(throws: FileProbe.Failure.isDirectory) { try FileReading.read(url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        #expect(throws: FileProbe.Failure.gone) { try FileReading.read(url) }
    }

    @Test func everyCaseSurvivesTheWire() throws {
        let stamp = FileStamp(size: 3, modifiedAt: Date(timeIntervalSince1970: 1_000_000))
        let cases: [FileReading] = [
            .text("abc", isTruncated: true, size: 9, stamp: stamp),
            .image(Data([1, 2, 3]), describedAs: "PNG image, 3 bytes", stamp: stamp),
            .other(describedAs: "Zip archive, 3 bytes", size: 3, stamp: stamp),
            .unchanged(stamp),
        ]
        for reading in cases {
            #expect(try roundTrip(reading) == reading)
        }
    }
}
