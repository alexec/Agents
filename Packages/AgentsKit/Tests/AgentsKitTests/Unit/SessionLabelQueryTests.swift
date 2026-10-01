import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Session label search")
struct SessionLabelQueryTests {
    private func agent(_ title: String, labels: [String]) -> Agent {
        Agent(runtimeID: "claude", cwd: URL(filePath: "/work/api"), title: title,
              labels: labels.map { SessionLabel(value: $0, owner: .person) })
    }

    @Test func labelAndTextAreCombined() {
        let all = [agent("Make parser fast", labels: ["perf"]),
                   agent("Make build fast", labels: ["build"]),
                   agent("Inspect parser", labels: ["perf"])]
        let query = SessionLabelQuery("label:PERF parser")
        #expect(all.filter(query.matches).count == 2)
        #expect(SessionLabelQuery("label:perf fast").matches(all[0]))
        #expect(!SessionLabelQuery("label:perf fast").matches(all[1]))
    }

    @Test func missingLabelDoesNotShowEverySession() {
        let item = agent("Parser", labels: ["perf"])
        #expect(!SessionLabelQuery("label:missing").matches(item))
        #expect(!SessionLabelQuery("label:").matches(item))
    }

    @Test func quotedLabelCanContainSpaces() {
        let item = agent("Parser", labels: ["long task"])
        #expect(SessionLabelQuery("label:\"LONG TASK\"").matches(item))
    }

    @Test func workflowsMatchByNameAndNeverByLabel() {
        let nightly = WorkflowSummary(workflow: Workflow(workflowID: "nightly", folder: URL(filePath: "/work/api"),
                                                         name: "Nightly build"))
        #expect(SessionLabelQuery("night").matches(nightly))
        #expect(SessionLabelQuery("").matches(nightly))
        #expect(!SessionLabelQuery("parser").matches(nightly))
        #expect(!SessionLabelQuery("label:perf").matches(nightly))
    }

    @Test func twoHundredSessionsStayCheap() {
        let all = (0..<200).map { index in
            agent("Session \(index)", labels: index.isMultiple(of: 50) ? ["perf"] : ["other"])
        }
        let query = SessionLabelQuery("label:perf")
        let start = ContinuousClock.now
        let found = all.filter(query.matches)
        #expect(found.count == 4)
        #expect(start.duration(to: .now) < .seconds(1))
    }
}
