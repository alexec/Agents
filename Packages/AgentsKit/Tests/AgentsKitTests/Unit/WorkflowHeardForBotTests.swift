import Foundation
import Testing
@testable import AgentsKitCore

/// A bot's workflow heard on a person's machine (#2027): read from the wire, offered no
/// Run now, and said the same way on the window and the Remote as on the web page.
@Suite("A bot's workflow heard here")
struct WorkflowHeardForBotTests {
    private let workflow = Workflow(workflowID: "merged", folder: URL(filePath: "/tmp/work/app"), name: "Merged")

    @Test func itIsReadFromTheWireAndRunsOnlyOnTheBotsMachines() throws {
        var summary = WorkflowSummary(workflow: workflow)
        #expect(summary.runsHere && summary.hearsForText == nil)
        #expect(summary.approveDetail == "Read the prompt and settings below, then Approve to let it run")
        summary.hearsFor = "review-bot"
        let read = try JSONDecoder().decode(WorkflowSummary.self, from: JSONEncoder().encode(summary))
        #expect(read.hearsFor == "review-bot")
        #expect(!read.runsHere)
        #expect(read.hearsForText == "Heard here for review-bot — review-bot's machines run it")
        #expect(read.approveDetail == "Read its triggers below, then Approve to let your servers hear them for review-bot")
    }
}
