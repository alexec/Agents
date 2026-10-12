import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Everything waiting for the person's OK is one list on the project's summary (#773):
/// project MCP servers, plugins, guarded files, workflows and archive requests, each with
/// the answers its host takes. Deny leaves an item off and out of the list until it
/// changes again; Request changes goes only to an agent that made the change.
@Suite("One list of approvals", .timeLimit(.minutes(1)))
struct ApprovalsTests {
    private struct Setup {
        var core: DaemonCore
        var project: URL
        var lead: UUID
    }

    private func setUp() async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsApprovals-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: project.appending(path: ".agents"), withIntermediateDirectories: true)
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let store = try AgentStore(locations: locations)
        let lead = Agent(runtimeID: "claude", cwd: project, title: "Lead", state: .finished, endedReason: .endTurn)
        try await store.save(lead)
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        _ = try await core.addProject(project)
        // Begun on an empty project: nothing is approved as it stands.
        await core.beginPluginApprovalsIfNeeded()
        await core.beginMCPApprovalsIfNeeded()
        return Setup(core: core, project: project, lead: lead.id)
    }

    private func approvals(_ s: Setup) async -> [Approval] {
        await s.core.projectSummary(for: s.project)?.approvals ?? []
    }

    private func writeMCP(_ url: String, in s: Setup) async throws {
        try Data(#"{"mcpServers":{"ci":{"type":"http","url":"\#(url)"}}}"#.utf8)
            .write(to: s.project.appending(path: ".agents/mcp.json"))
        await s.core.projectFilesChanged([s.project.appending(path: ".agents/mcp.json")], in: s.project)
    }

    private func writePlugin(hook: String, in s: Setup) async throws {
        let url = s.project.appending(path: ".agents/plugins/deploy")
        try FileManager.default.createDirectory(at: url.appending(path: "hooks"), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\#(hook)"}]}]}}"#.utf8)
            .write(to: url.appending(path: "hooks/hooks.json"))
        await s.core.projectFilesChanged([url.appending(path: "hooks/hooks.json")], in: s.project)
    }

    @Test func anMCPServerWaitsAndDenyKeepsItOffUntilItChanges() async throws {
        let s = try await setUp()
        try await writeMCP("https://one.example", in: s)

        let item = try #require(await approvals(s).first { $0.kind == .mcpServer })
        #expect(item.key == "ci")
        #expect(item.line == "New MCP server")
        #expect(item.actions == [.approve, .deny], "no agent to ask for changes")
        let reading = try await s.core.readApproval(.init(folder: s.project, kind: .mcpServer, key: "ci"))
        #expect(reading.current?.contains("https://one.example") == true)
        #expect(reading.digest == item.digest)

        await #expect(throws: JSONRPCError.self, "Request changes is not offered where no agent made it") {
            _ = try await s.core.answerApproval(.init(item, in: s.project, action: .requestChanges, note: "use two"))
        }
        let denied = try await s.core.answerApproval(.init(item, in: s.project, action: .deny))
        #expect(denied.approvals?.contains { $0.kind == .mcpServer } != true, "denied, it leaves the list")
        let listed = try await s.core.mcpList(.init(destination: .project(folder: s.project.path)))
        guard case .waiting = try #require(listed.servers.first).approval else {
            Issue.record("a denied server stays off")
            return
        }

        try await writeMCP("https://two.example", in: s)
        let again = try #require(await approvals(s).first { $0.kind == .mcpServer }, "changed, it asks again")
        #expect(again.line == "New MCP server", "never approved, so still new")
        let approved = try await s.core.answerApproval(.init(again, in: s.project, action: .approve))
        #expect(approved.approvals == nil)
    }

    @Test func aPluginWaitsSayingWhatItBrings() async throws {
        let s = try await setUp()
        try await writePlugin(hook: "echo one", in: s)

        let item = try #require(await approvals(s).first { $0.kind == .plugin })
        #expect(item.key == "deploy")
        #expect(item.line == "New plugin, with hooks")
        let reading = try await s.core.readApproval(.init(folder: s.project, kind: .plugin, key: "deploy"))
        #expect(reading.current?.contains("hooks/hooks.json") == true)

        _ = try await s.core.answerApproval(.init(item, in: s.project, action: .deny))
        #expect(await approvals(s).isEmpty)
        #expect(await s.core.approvedPluginFolders(for: s.project).isEmpty, "denied, it stays out")

        try await writePlugin(hook: "echo two", in: s)
        let again = try #require(await approvals(s).first { $0.kind == .plugin })
        await #expect(throws: JSONRPCError.self, "only the version shown") {
            _ = try await s.core.answerApproval(.init(folder: s.project, kind: .plugin, key: "deploy",
                                                     digest: item.digest, action: .approve))
        }
        _ = try await s.core.answerApproval(.init(again, in: s.project, action: .approve))
        #expect(await approvals(s).isEmpty)
        #expect(await s.core.approvedPluginFolders(for: s.project).count == 1)
    }

    @Test func aFileAnAgentChangedTakesRequestChangesAndUndo() async throws {
        let s = try await setUp()
        _ = try await s.core.setHelperLimits(.init(folder: s.project, limits: HelperLimits(running: 2)))
        await s.core.startTurnForTesting(s.lead)
        let file = GuardedFile.projectConfig.url(in: s.project)
        try Data(#"{"helperLimits": {"running": 10}}"#.utf8).write(to: file)
        await s.core.projectFilesChanged([s.project.appending(path: ".agents")], in: s.project)

        let item = try #require(await approvals(s).first { $0.kind == .file })
        #expect(item.key == ".agents/project.json")
        #expect(item.line == "Changed by Lead")
        #expect(item.actions == [.approve, .deny, .requestChanges])
        #expect(item.agentID == s.lead)

        await #expect(throws: JSONRPCError.self, "a note is needed") {
            _ = try await s.core.answerApproval(.init(item, in: s.project, action: .requestChanges, note: "  "))
        }
        let summary = try await s.core.answerApproval(.init(item, in: s.project, action: .deny))
        #expect(summary.approvals == nil, "Undo put the approved copy back")
        #expect(await s.core.helperLimits(in: s.project).running == 2)
    }

    @Test func anArchiveRequestIsListedAndDenyKeepsTheSession() async throws {
        let s = try await setUp()
        try await s.core.requestArchive(s.lead)

        let item = try #require(await approvals(s).first { $0.kind == .archive })
        #expect(item.key == s.lead.uuidString)
        #expect(item.isSession, "drawn as the session's own row")
        #expect(item.agentID == s.lead)

        let summary = try await s.core.answerApproval(.init(item, in: s.project, action: .deny))
        #expect(summary.approvals == nil)
        let agent = try #require(await s.core.agent(s.lead))
        #expect(!agent.asksToArchive)
        #expect(agent.state != .archived, "kept")
    }

    @Test func anItemFromANewerHostDropsOnlyItself() throws {
        let json = #"""
        {"project":{"folder":"file:///w/","addedAt":0},"name":"w","exists":true,"lastActivityAt":0,
         "counts":{},"costToDate":{},"unmeasuredAgents":0,
         "approvals":[{"kind":"secret","key":"a","title":"a","line":"","actions":["approve"]},
                      {"kind":"workflow","key":"b","title":"B","line":"New","actions":["approve","shrug"]}]}
        """#
        let summary = try JSONDecoder().decode(DaemonAPI.ProjectSummary.self, from: Data(json.utf8))
        #expect(summary.approvals?.map(\.key) == ["b"])
        #expect(summary.approvals?.first?.actions == [.approve])
    }
}
