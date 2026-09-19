import Foundation
import Testing
@testable import AgentsKit

/// A transcript that stalls on one big thing is a transcript nobody scrolls.
///
/// These measure the part that can be measured without a trackpad: reading and holding
/// the content. How it draws is checked by hand, and what was measured is written down
/// in the quickstart.
@Suite("Big things in a transcript")
struct BigContentTests {
    private func megabyte(of line: String) -> String {
        let repeats = (1_000_000 / max(1, line.utf8.count)) + 1
        return String(repeating: line, count: repeats)
    }

    @Test func aMegabyteDiffIsReadQuickly() throws {
        let old = megabyte(of: "let value = 1\n")
        let new = megabyte(of: "let value = 2\n")
        let wire: JSONValue = ["type": "diff", "path": "/tmp/big.swift",
                               "oldText": .string(old), "newText": .string(new)]
        let started = ContinuousClock.now
        guard case .diff(let diff) = ToolCallContent(wire: wire) else {
            Issue.record("expected a diff")
            return
        }
        let lines = diff.newText.split(separator: "\n", omittingEmptySubsequences: false).count
        let took = ContinuousClock.now - started
        #expect(lines > 70_000)
        #expect(took < .milliseconds(500), "read a megabyte of diff in \(took)")
    }

    @Test func aLongRunningCommandCannotGrowWithoutLimit() async throws {
        let service = TerminalService(scope: FolderScope(folders: [URL(filePath: "/tmp")]),
                                      defaultCWD: URL(filePath: "/tmp"))
        // Twenty times the cap, one chunk at a time, the way a chatty command arrives.
        let chunk = String(repeating: "output ", count: 1_000)
        let started = ContinuousClock.now
        for _ in 0..<700 { await service.appendForTesting(chunk, to: "t1") }
        let took = ContinuousClock.now - started
        let output = await service.output(id: "t1")
        let kept = output["output"]?.stringValue?.utf8.count ?? 0
        #expect(kept <= TerminalService.outputByteLimit)
        #expect(output["truncated"]?.boolValue == true, "truncation is flagged, not silent")
        #expect(took < .seconds(2), "held \(kept) bytes of a much longer stream in \(took)")
    }

    @Test func aHugeMessageIsStillOneEntry() {
        let text = megabyte(of: "The quick brown fox. ")
        let update = SessionUpdate.decode(["sessionUpdate": "agent_message_chunk",
                                           "content": ["type": "text", "text": .string(text)]])
        guard case .entry(.agentMessage(_, let read, _)) = update else {
            Issue.record("expected a message")
            return
        }
        #expect(read.utf8.count > 1_000_000)
    }
}
