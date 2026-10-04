import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An outcome message past the limit, driven through the real daemon (#184). It is
/// refused whole with the sentence that says how short, nothing is recorded, and the
/// agent's next call, with fewer words, lands in the same turn: a refusal never leaves
/// the turn unaccounted for.
@Suite("An outcome too long to keep", .timeLimit(.minutes(1)))
struct OutcomeLengthTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsOutcomeLengthTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    /// A turn long enough to call the tool twice in the middle of.
    private func midTurn() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        return FakeLauncher(script: script)
    }

    private func mintedToken(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let minted = MintedMCPToken.from(sessionParams: await launcher.lastAgent?.newSessionParams)
            return minted.isEmpty ? nil : minted
        } ?? ""
    }

    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let agent = await core.agent(id),
               !agent.state.hasTurnInFlight, agent.queuedPrompts.isEmpty,
               await core.live[id] == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private let long = """
        Fixed the redirect in AuthController.swift by checking the session token before \
        the cookie, which the middleware sets on every request, and added two tests that \
        cover the expired-token case and the missing-cookie case.
        """

    @Test(arguments: ["done", "needs_answer"])
    func aLongMessageIsRefusedAndTheRetryLands(_ outcome: String) async throws {
        #expect(long.count > WorkReport.messageLimit)
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "go"))
        let token = await mintedToken(launcher)

        let error = await #expect(throws: JSONRPCError.self) {
            _ = try await core.finishTurn(.init(token: token, outcome: outcome,
                                                message: long, prompts: []))
        }
        #expect(error?.code == JSONRPCError.invalidParams)
        #expect(error?.message == WorkReport.tooLong(WorkOutcome(wire: outcome)))
        #expect(await core.agent(id)?.report == nil, "nothing was recorded")

        let short = outcome == "done" ? "Login works again." : "Should expired sessions sign out?"
        _ = try await core.finishTurn(.init(token: token, outcome: outcome,
                                            message: short, prompts: []))
        #expect(await core.agent(id)?.report?.message == short)

        try await settle(core, id)
        let agent = try #require(await core.agent(id))
        #expect(agent.report?.outcome == WorkOutcome(wire: outcome))
        #expect(agent.report?.message == short)
    }
}
