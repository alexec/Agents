import Foundation
import Testing
@testable import AgentsKitCore

/// One agent a client cannot read costs that row, not the whole list (#2650).
@Suite("A list of agents with one bad row")
struct AgentRowsTests {
    /// Two good agents around one whose worktree has `"folder": ""`, as #2617 left them.
    private func listed() throws -> JSONValue {
        let good = { try JSONValue.encoding(Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp/repo"))) }
        let bad = try JSONValue.parse(Data("""
        {"id": "388ECC50-0000-4000-8000-000000000000", "runtimeID": "claude", "cwd": "file:///tmp/repo/",
         "worktree": {"name": "lane", "root": "file:///tmp/repo/.agents/worktrees/lane/", "madeByApp": true, "folder": ""}}
        """.utf8))
        return .array([try good(), bad, try good()])
    }

    @Test func theBadRowIsLeftOutAndTheRestAreListed() throws {
        let value = try listed()
        #expect(throws: DecodingError.self) { try value.decode([Agent].self) }
        #expect(try Agent.list(value).count == 2)
    }

    @Test func theCatchUpKeepsTheRest() throws {
        let snapshot = DaemonAPI.CatchUpSnapshot(folders: [], agents: [], permissions: [], elicitations: [],
                                                 attention: .init(needs: [], deliveries: []), resuming: [])
        guard case .object(var fields) = try JSONValue.encoding(snapshot) else { Issue.record("not an object"); return }
        fields["agents"] = try listed()
        let read = try JSONValue.object(fields).decode(DaemonAPI.CatchUpSnapshot.self)
        #expect(read.agents.count == 2)
    }

    @Test func aValueThatIsNotAListStillFails() {
        #expect(throws: DecodingError.self) { try Agent.list(.string("no")) }
    }
}
