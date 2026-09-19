import Foundation
import Testing
@testable import AgentsKit

/// The payloads below were captured from the real runtimes on 2026-09-18 and are
/// written out here exactly as they arrived.
@Suite("What a tool call produced")
struct ToolCallContentTests {
    @Test func copilotSendsAStructuredDiff() {
        let wire: JSONValue = ["type": "diff", "path": "/tmp/acp-audit-copilot/notes.txt",
                               "oldText": "original line\n", "newText": "edited line\n"]
        guard case .diff(let diff) = ToolCallContent(wire: wire) else {
            Issue.record("expected a diff")
            return
        }
        #expect(diff.fileName == "notes.txt")
        #expect(diff.oldText == "original line\n")
        #expect(diff.newText == "edited line\n")
    }

    @Test func grokSendsTheSameThingWithExtrasWeIgnore() {
        let wire: JSONValue = ["type": "diff", "path": "/tmp/acp-audit-grok/notes.txt",
                               "oldText": "original", "newText": "edited",
                               "_meta": ["old_line": 1, "new_line": 1]]
        guard case .diff(let diff) = ToolCallContent(wire: wire) else {
            Issue.record("expected a diff")
            return
        }
        #expect(diff.oldText == "original")
    }

    @Test func theClaudeAdapterSendsConsoleTextInstead() {
        // It shells out, so its edits arrive as content rather than as a diff. Drawn
        // as text rather than invented into a diff we do not have.
        let wire: JSONValue = ["type": "content",
                               "content": ["type": "text", "text": "```console\nedited line\n```"]]
        guard case .content(let block) = ToolCallContent(wire: wire) else {
            Issue.record("expected content")
            return
        }
        #expect(block.text?.contains("edited line") == true)
    }

    @Test func aTerminalBlockIsAPointerToATerminalWeAreRunning() {
        guard case .terminal(let id) = ToolCallContent(wire: ["type": "terminal", "terminalId": "t1"]) else {
            Issue.record("expected a terminal")
            return
        }
        #expect(id == "t1")
    }

    @Test func contentWeDoNotRecogniseIsKeptRatherThanDropped() {
        let odd: JSONValue = ["type": "sculpture", "marble": true]
        #expect(ToolCallContent(wire: odd) == .unknown(odd))
        #expect(ToolCallContent(wire: odd).wire == odd)
    }

    @Test func aDiffWithNoNewTextIsNotADiff() {
        let half: JSONValue = ["type": "diff", "path": "/tmp/a"]
        if case .unknown = ToolCallContent(wire: half) {} else { Issue.record("expected unknown") }
    }

    @Test func locationsCarryTheirLine() {
        let location = ToolCallLocation(wire: ["path": "/tmp/notes.txt", "line": 12])
        #expect(location?.line == 12)
        #expect(location?.fileName == "notes.txt")
        #expect(ToolCallLocation(wire: ["line": 3]) == nil)
    }

    @Test func contentSurvivesBeingWrittenDown() throws {
        let content: [ToolCallContent] = [.diff(.init(path: "/a", oldText: nil, newText: "x")),
                                          .content(.text("hi")),
                                          .terminal("t1")]
        let data = try JSONEncoder().encode(content)
        #expect(try JSONDecoder().decode([ToolCallContent].self, from: data) == content)
    }
}
