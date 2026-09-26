import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A plan put to the person for approval is shown to them as a page, the way any
/// document an agent writes is, and a device may read that one file although it is
/// outside the agent's folders.
@Suite("Approving a plan", .timeLimit(.minutes(1)))
struct PlanApprovalTests {
    private func temporary() throws -> (StoreLocations, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsPlanTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let plans = root.appendingPathComponent("plans", isDirectory: true)
        for folder in [work, plans] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return (StoreLocations(root: root), work, plans)
    }

    /// The request as Claude's adapter sends `ExitPlanMode`, trimmed.
    private func approval(planFile: String) -> JSONValue {
        ["toolCall": ["toolCallId": "t1", "title": "Approve Plan", "kind": "switch_mode",
                      "rawInput": ["plan": "# The plan\n\nDo it.", "planFilePath": .string(planFile)],
                      "content": [["type": "content", "content": ["type": "text", "text": "# The plan"]]]],
         "options": [["optionId": "exit-plan-auto", "name": "Yes, and use auto mode", "kind": "allow_always"],
                     ["optionId": "exit-plan-default", "name": "Yes, manually approve edits", "kind": "allow_once"],
                     ["optionId": "reject", "name": "No, keep planning", "kind": "reject_once"]]]
    }

    @Test func thePlanFileIsNamedOnlyForAPlanApproval() {
        let plan = ToolCall(title: "Approve Plan", kind: "switch_mode",
                            rawInput: ["plan": "x", "planFilePath": "/Users/me/.claude/plans/a.md"])
        #expect(plan.isPlanApproval)
        #expect(plan.planFile?.path == "/Users/me/.claude/plans/a.md")
        #expect(plan.planText == "x")

        let edit = ToolCall(title: "Write", kind: "edit", rawInput: ["planFilePath": "/a.md"])
        #expect(edit.planFile == nil)
        let relative = ToolCall(title: "Approve Plan", kind: "switch_mode",
                                rawInput: ["planFilePath": "plans/a.md"])
        #expect(relative.planFile == nil)
        let notMarkdown = ToolCall(title: "Approve Plan", kind: "switch_mode",
                                   rawInput: ["planFilePath": "/tmp/a.txt"])
        #expect(notMarkdown.planFile == nil)
    }

    @Test func thePlanIsShownAndOnlyThatFileMayBeRead() async throws {
        let (locations, work, plans) = try temporary()
        let planFile = plans.appendingPathComponent("snazzy.md")
        try Data("# The plan\n".utf8).write(to: planFile)
        let neighbour = plans.appendingPathComponent("someone-elses.md")
        try Data("# Not yours\n".utf8).write(to: neighbour)

        var script = FakeACPAgent.Script()
        script.permission = approval(planFile: planFile.path)
        let launcher = FakeLauncher(script: script)
        let heard = Broadcasts()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.setBroadcaster { method, params in Task { await heard.record(method, params) } }
        await core.setConnectionCount(1)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "plan it"))
        await eventually("the plan is put to the person") { await core.agent(id)?.state == .waitingOnUser }

        let shown = await heard.wait(for: DaemonAPI.Notification.agentShowFile)
        #expect(shown?["agentID"]?.stringValue == id.uuidString)
        #expect(shown?["file"]?["path"]?.stringValue == planFile.path)

        let reading = try await core.readFile(.init(agentID: id, path: planFile.path))
        guard case .text(let text, _, _, _) = reading else {
            Issue.record("the plan was not read as text: \(reading)"); return
        }
        #expect(text.contains("The plan"))
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.readFile(.init(agentID: id, path: neighbour.path))
        }

        let waiting = await core.pendingPermissionRequests()
        try await core.answerPermission(.init(permissionID: waiting[0].id, optionID: "exit-plan-auto"))
        await eventually("the turn ran on") { await core.agent(id)?.state == .finished }
        #expect(await launcher.lastAgent?.permissionOutcome?["outcome"]?["optionId"]?.stringValue
                == "exit-plan-auto")
    }

    /// What the daemon told the windows.
    private actor Broadcasts {
        private var sent: [(String, JSONValue?)] = []

        func record(_ method: String, _ params: JSONValue?) { sent.append((method, params)) }

        func wait(for method: String) async -> JSONValue? {
            let deadline = ContinuousClock.now.advanced(by: max(.seconds(2), Eventually.timeout))
            while ContinuousClock.now < deadline {
                if let found = sent.first(where: { $0.0 == method }) { return found.1 }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
    }
}
