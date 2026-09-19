import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("What a file is, from its first bytes")
struct FileProbeTests {
    private func write(_ data: Data, named name: String) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func plainTextIsText() throws {
        let url = try write(Data("hello, world\nsecond line\n".utf8), named: "notes.txt")
        let probe = try FileProbe.read(url)
        #expect(probe.kind == .text)
        #expect(probe.text == "hello, world\nsecond line\n")
        #expect(probe.isTruncated == false)
    }

    @Test func anEmptyFileIsText() throws {
        // There is nothing in it to be binary, and an empty pane is the right answer.
        let url = try write(Data(), named: "empty.txt")
        let probe = try FileProbe.read(url)
        #expect(probe.kind == .text)
        #expect(probe.size == 0)
        #expect(probe.text == "")
    }

    @Test func aPNGIsBinaryAndIsDescribedRatherThanShown() throws {
        // The real 8-byte PNG signature, which carries a NUL in the fourth byte.
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        bytes.append(Data(repeating: 0, count: 64))
        let url = try write(bytes, named: "logo.png")
        let probe = try FileProbe.read(url)
        #expect(probe.kind.isText == false)
        guard case .binary(let description) = probe.kind else {
            Issue.record("expected binary")
            return
        }
        #expect(description.contains("PNG image"))
        #expect(probe.text == nil)
    }

    @Test func utf16WithAByteOrderMarkIsBinary() throws {
        // Its ASCII is NUL-padded, so it trips the NUL rule. Showing its bytes as text
        // would draw every other character as a blank, which is worse than saying what
        // it is.
        var bytes = Data([0xFF, 0xFE])
        bytes.append(contentsOf: Array("hello".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let url = try write(bytes, named: "wide.txt")
        let probe = try FileProbe.read(url)
        #expect(probe.kind.isText == false)
    }

    @Test func validForTheWholePrefixAndRubbishAfterItIsStillText() throws {
        // The probe reads a prefix, so what comes after it cannot change the answer.
        // This is FR-015 and FR-014 meeting: the decision is made on what was read.
        var bytes = Data(String(repeating: "a", count: FileProbe.sniffLimit + 16).utf8)
        bytes.append(Data(repeating: 0, count: 1024))
        let url = try write(bytes, named: "mostly.txt")
        let probe = try FileProbe.read(url)
        #expect(probe.kind == .text)
    }

    @Test func aLargeFileIsReadOnlyToItsLimit() throws {
        let size = FileProbe.prefixLimit * 3
        let url = try write(Data(repeating: UInt8(ascii: "x"), count: size), named: "big.log")
        let probe = try FileProbe.read(url)
        #expect(probe.kind == .text)
        #expect(probe.prefix.count == FileProbe.prefixLimit)
        #expect(probe.isTruncated)
        // The size is the file's, not the number of bytes read. FR-015 says not to read
        // a whole large file to show the start of it.
        #expect(probe.size == size)
    }

    @Test func aPrefixCutMidCharacterIsNotBinary() throws {
        // A multi-byte character straddling the read limit must not make a text file
        // look binary.
        let pound = Array("£".utf8)
        var bytes = Data(String(repeating: "a", count: FileProbe.sniffLimit - 1).utf8)
        bytes.append(pound[0])
        #expect(FileProbe.classify(bytes, filename: "x.txt", size: bytes.count) == .text)
    }

    @Test("A run of multi-byte characters cut at the sniff limit is not binary",
          arguments: ["é", "─", "😀"])
    func aRunOfMultiByteCharactersCutAtTheLimitIsNotBinary(_ character: String) throws {
        // The shape that broke: dropping a fixed three bytes to forgive the cut lands on
        // another lead byte when the window is a *run* of multi-byte characters. Found by
        // a wireframe full of box drawing opening as "MD file, 21 KB".
        let unit = Array(character.utf8)
        for cut in 1..<unit.count {
            var bytes = Data()
            while bytes.count + unit.count <= FileProbe.sniffLimit - cut {
                bytes.append(contentsOf: unit)
            }
            bytes.append(Data(repeating: UInt8(ascii: "a"),
                              count: FileProbe.sniffLimit - cut - bytes.count))
            bytes.append(contentsOf: unit.prefix(cut))
            #expect(bytes.count == FileProbe.sniffLimit)
            #expect(FileProbe.classify(bytes, filename: "notes.md", size: bytes.count) == .text,
                    "\(character) cut after \(cut) byte(s)")
        }
    }

    @Test func aFileOfBoxDrawingOpensAsText() throws {
        // The whole path, not just the classifier: the wireframe that started this is
        // box drawing past the sniff limit and well under the read limit.
        let line = String(repeating: "─", count: 64) + "\n"
        var content = ""
        while content.utf8.count < FileProbe.sniffLimit * 2 { content += line }
        let url = try write(Data(content.utf8), named: "wireframe.md")
        let probe = try FileProbe.read(url)
        #expect(probe.kind == .text)
        #expect(probe.isTruncated == false)
        #expect(probe.text == content)
    }

    @Test func aMissingFileSaysSoRatherThanReadingEmpty() throws {
        let url = URL.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).txt")
        #expect(throws: FileProbe.Failure.gone) { try FileProbe.read(url) }
    }

    @Test func aDirectoryIsNotAFile() throws {
        let directory = URL.temporaryDirectory.appending(path: "probe-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: FileProbe.Failure.isDirectory) { try FileProbe.read(directory) }
    }
}
