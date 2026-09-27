import Testing
@testable import AgentsKitCore

@Suite("Copilot errors after its tool notice")
struct CopilotTurnErrorTests {
    private let notice = "Info: Disabled tools: list_agents, read_agent, task, write_agent"
    private let error = "Error: You have exceeded your monthly quota (Request ID: captured)"

    @Test(arguments: ["", "\n", "\r\n"])
    func noticeDoesNotHideTheFailure(separator: String) {
        let failure = RuntimeLaunchCatalog.copilot.turnError(in: notice + separator + error)
        #expect(failure?.sentence == "You have exceeded your monthly quota (Request ID: captured)")
    }

    @Test func ordinaryRepliesAndQuotedErrorsAreNotFailures() {
        for text in [notice, notice + "Hello!", "I saw " + error,
                     notice + "The log says: " + error,
                     "Info: Something else happened\n" + error] {
            #expect(RuntimeLaunchCatalog.copilot.turnError(in: text) == nil)
        }
        #expect(RuntimeLaunchCatalog.antigravity.turnError(in: notice + error) == nil)
    }
}
