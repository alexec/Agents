import Foundation
import Testing
@testable import AgentsKitCore

/// A user workflow says it is in every folder (#2759) on its page and in its row's help,
/// wherever the row is, in the words the web page says too.
@Suite("A user workflow says it is in every folder")
struct WorkflowScopeSentenceTests {
    private let workflow = Workflow(workflowID: "tidy", folder: URL(filePath: "/tmp/work/app"), name: "Tidy",
                                    triggers: [], prompt: "Tidy up")

    @Test func aUserWorkflowSaysSoAndAFoldersOwnSaysNothing() {
        let own = WorkflowSummary(workflow: workflow)
        #expect(own.scopeSentence == nil)
        #expect(own.rowHelp == workflow.summary)
        let user = WorkflowSummary(workflow: workflow, scope: "user")
        #expect(user.scopeSentence == "Your workflow: in every folder")
        #expect(user.rowHelp == "\(workflow.summary)\nYour workflow: in every folder")
        let off = WorkflowSummary(workflow: workflow, scope: "user", isEnabled: false)
        #expect(off.rowHelp == "Turned off. \(workflow.summary)\nYour workflow: in every folder")
    }
}
