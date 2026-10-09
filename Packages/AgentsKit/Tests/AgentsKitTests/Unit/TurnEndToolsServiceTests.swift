import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The tools that took over `finish_turn`'s other jobs (#481), as the app's server reads
/// them before the daemon hears them.
@Suite("The turn-end tools")
struct TurnEndToolsServiceTests {
    private actor Calls {
        var made: [AppService.SelfCall] = []
        func add(_ call: AppService.SelfCall) { made.append(call) }
    }

    private func call(_ service: AppService, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        try await service.handle(method: "tools/call", params: ["name": .string(name), "arguments": arguments]).get()
    }

    private func service(_ calls: Calls, managesAgents: Bool = true, movesItself: Bool = true) -> AppService {
        AppService(transport: nil, managesAgents: managesAgents, movesItself: movesItself,
                   itself: { call in await calls.add(call); return .shown("Noted.") })
    }

    @Test func parkAndArchiveWithNoIdAreTheCallerItselfEvenForAHelper() async throws {
        let calls = Calls()
        let helper = service(calls, managesAgents: false)
        _ = try await call(helper, "mcp__agents__park_agent", [:])
        _ = try await call(helper, "mcp__agents__archive_agent", ["id": " "])
        #expect(await calls.made == [.afterTurn(.park), .afterTurn(.archive)])
        // With an id it is still a helper's, and refused to an agent another started.
        let refused = try await call(helper, "park_agent", ["id": "abc"])
        #expect(refused["isError"]?.boolValue == true)
        #expect(await calls.made.count == 2)
    }

    @Test func aWaitOnAgentsOrATimeIsTheOldBlock() async throws {
        let calls = Calls()
        let tools = service(calls)
        _ = try await call(tools, "wait_for_event", ["agents": ["Lane A", "Lane B"], "wake_on": "any",
                                                     "until_minutes": 30, "message": "Waiting on the lanes."])
        _ = try await call(tools, "wait_for_event", ["until_minutes": "5"])
        #expect(await calls.made == [
            .waitOn(agents: ["Lane A", "Lane B"], wakeOn: .any, untilMinutes: 30, message: "Waiting on the lanes."),
            .waitOn(agents: [], wakeOn: nil, untilMinutes: 5, message: nil),
        ])
        for bad: JSONValue in [["agents": ["A"], "events": ["agent.finished"]],
                               ["agents": ["A"], "wake_on": "first"],
                               ["until_minutes": 0]] {
            let result = try await call(tools, "wait_for_event", bad)
            #expect(result["isError"]?.boolValue == true, "\(bad)")
        }
        #expect(await calls.made.count == 2)
        // A wait on events is still an event wait, never a block.
        #expect(AppService.selfCall(named: "wait_for_event", ["events": ["custom.x"], "until_minutes": 5],
                                    movesItself: true) == nil)
    }

    @Test func labelsAndMovesReachTheSink() async throws {
        let calls = Calls()
        let tools = service(calls)
        _ = try await call(tools, "set_session_labels", ["add": ["deploy"], "remove": "old"])
        _ = try await call(tools, "move_worktree", ["leave_worktree": "remove"])
        _ = try await call(tools, "move_worktree", [:])
        #expect(await calls.made == [
            .labels(add: ["deploy"], remove: ["old"]),
            .move(.move(target: .projectFolder, removeLeft: true, discardChanges: false)),
            .move(nil),
        ])
        let empty = try await call(tools, "set_session_labels", [:])
        #expect(empty["isError"]?.boolValue == true)
    }

}
