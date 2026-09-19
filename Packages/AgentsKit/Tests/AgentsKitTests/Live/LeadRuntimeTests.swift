import Foundation
import Testing
@testable import AgentsKit

/// What the real runtimes do with a project lead's tools.
///
/// Off unless `AGENTS_LIVE=1`, because these start real CLIs against real credentials
/// and cost real money.
///
/// The question this suite exists to answer is the one the design could not settle by
/// reasoning: **which runtimes ask their own permission question before calling an MCP
/// tool, on top of the one we ask?** We hold every changing tool call and raise our own
/// question, because an answer given inside a runtime is invisible to us — so "always"
/// would live somewhere we cannot read. A runtime that also asks means two prompts for
/// one action, and we cannot suppress its. So we find out which do it and write it
/// down, rather than designing around a guess.
@Suite("A lead against a real runtime", .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"))
struct LeadRuntimeTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsLeadLive-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    @Test(arguments: ["claude", "grok", "copilot"])
    func aLeadIsOfferedItsToolsAndCallsThem(runtimeID: String) async throws {
        let (locations, work) = try temporary()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations)
        await core.loadFromDisk()

        let project = try await core.addProject(work)
        let leadID = try #require(project.leadID)

        // Ask it to do the one thing only a lead can do. What we are watching for is
        // whether a permission question of the runtime's own arrives before ours.
        try await core.prompt(DaemonAPI.PromptRequest(
            agentID: leadID,
            text: "Use your tools to list the agents in this project, then say how many there are."))

        // Give the turn time to reach a tool call.
        for _ in 0..<60 {
            if await core.agent(leadID)?.state != .running { break }
            try await Task.sleep(for: .seconds(1))
        }

        let entries = try await core.transcript(
            DaemonAPI.TranscriptRequest(agentID: leadID, limit: 200)).entries
        let text = entries.compactMap(\.text).joined(separator: "\n")

        // Not an assertion about which way it went: a record of it. Both answers are
        // findings, and the failure to record is the only real failure here.
        let calledOurTool = text.contains("list_agents")
        Issue.record("\(runtimeID): called list_agents = \(calledOurTool)")
        #expect(await core.agent(leadID)?.role == .lead)
    }
}
