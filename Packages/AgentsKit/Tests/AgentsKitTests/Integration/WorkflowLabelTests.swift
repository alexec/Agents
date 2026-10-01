import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Workflow session labels", .timeLimit(.minutes(1)))
struct WorkflowLabelTests {
    private let file = """
        ---
        on:
          - schedule:
              at: [":00"]
        agent: new
        labels: [Review, morning]
        ---

        Check the build.
        """

    @Test func frontMatterParsesLabelSequenceWithoutChangingRuntimeOptions() {
        let workflow = WorkflowFile.parse(file, workflowID: "morning", in: URL(filePath: "/tmp/work"))
        #expect(workflow.problem == nil)
        #expect(workflow.settings.labels == ["Review", "morning"])
        #expect(workflow.settings.isEmpty)
    }

    @Test func invalidLabelFrontMatterIsRefusedBeforeAWorkflowCanStart() {
        let invalid = file.replacingOccurrences(of: "labels: [Review, morning]",
                                                 with: "labels: [one, two, three, four, five, six]")
        let workflow = WorkflowFile.parse(invalid, workflowID: "morning", in: URL(filePath: "/tmp/work"))
        #expect(workflow.problem != nil)
    }

    @Test func aNewWorkflowSessionStartsWithAgentOwnedLabels() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkflowLabels-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("work", isDirectory: true)
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(file.utf8).write(to: WorkflowFile.url(for: "morning", in: project))
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        await core.rescanWorkflows(in: project)
        _ = try await core.runWorkflow(.init(folder: project, workflowID: "morning"))
        let agent = await core.allAgents().first
        #expect(agent?.labels.map(\.value) == ["Review", "morning"])
        #expect(agent?.labels.allSatisfy { $0.owner == .agent } == true)
    }
}
