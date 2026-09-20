import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Withdrawing a form", .timeLimit(.minutes(1)))
struct WithdrawDiagnosticTests {
    @Test func theSessionTakesTheFormDownWhenTheRuntimeCompletesItElsewhere() async throws {
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createElicitation,
            ["elicitationId": "e1", "mode": "form", "message": "Which branch?",
             "requestedSchema": ["title": "Which branch?",
                                 "properties": ["branch": ["type": "string", "title": "Branch"]],
                                 "required": ["branch"]]])]
        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine,
                                 capabilities: ACP.ClientCapabilities(elicitationForm: true,
                                                                      elicitationURL: true))
        let agent = FakeACPAgent(script: script, transport: theirs)
        try await session.initialize()
        try await session.newSession(cwd: URL(fileURLWithPath: "/tmp"))
        let turn = Task { try await session.prompt("go") }
        await eventually("the form is outstanding") {
            await session.outstandingElicitationIDs.count == 1
        }
        await agent.emitNotification(ACP.ClientMethod.completeElicitation, ["elicitationId": "e1"])
        await eventually("the form came down") {
            await session.outstandingElicitationIDs.isEmpty
        }
        #expect(await session.outstandingElicitationIDs.isEmpty)
        turn.cancel()
    }
}
