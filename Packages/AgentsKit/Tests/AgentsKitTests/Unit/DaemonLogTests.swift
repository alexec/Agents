import Foundation
import Testing
@testable import AgentsKit

/// The daemon's log: one kept handle, rolled at its limit (#177).
@Suite("Daemon log")
struct DaemonLogTests {
    private func temporary() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDaemonLog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("daemon.log")
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func linesAreAppendedInOrderWithATime() throws {
        let url = try temporary()
        try Data("2026-10-03T00:00:00Z from before\n".utf8).write(to: url)
        let log = DaemonLog()
        log.setDestination(url)
        for n in 1...100 { log.write("line \(n)") }
        let written = lines(url)
        #expect(written.count == 101, "appended to what was there")
        #expect(written.last?.hasSuffix(" line 100") == true)
        #expect(written[1].first?.isNumber == true, "each line starts with its time")
    }

    /// The handle is kept: a line after the file is removed goes to the open file, and
    /// the path is looked at again within `checkEvery` lines and the log started afresh.
    @Test func oneHandleIsKeptAndAMissingFileIsStartedAgain() throws {
        let url = try temporary()
        let log = DaemonLog()
        log.setDestination(url)
        log.write("first")
        try FileManager.default.removeItem(at: url)
        log.write("second")
        #expect(!FileManager.default.fileExists(atPath: url.path), "not opened again per line")
        for n in 1...300 { log.write("more \(n)") }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(lines(url).last?.hasSuffix(" more 300") == true)
    }

    @Test func itRollsAtItsLimit() throws {
        let url = try temporary()
        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
        let log = DaemonLog(limit: 4096)
        log.setDestination(url)
        for n in 1...200 { log.write("a line of about forty bytes, number \(n)") }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size <= 4096)
        #expect(FileManager.default.fileExists(atPath: previous.path))
        #expect(lines(url).last?.hasSuffix("number 200") == true, "the newest line is in the current log")
        let previousSize = try FileManager.default.attributesOfItem(atPath: previous.path)[.size] as? Int ?? 0
        #expect(previousSize <= 4096)
    }

    @Test func aLogAlreadyOverItsLimitIsRolledOnOpening() throws {
        let url = try temporary()
        try Data(repeating: UInt8(ascii: "x"), count: 5000).write(to: url)
        let log = DaemonLog(limit: 4096)
        log.setDestination(url)
        log.write("fresh")
        #expect(lines(url).count == 1)
    }
}
