import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Where failing open is unsafe, an unreadable file fails closed (#205): spending limits
/// start nothing new and say so; approvals that lost `approvalsBegan`, or lost their
/// file, approve nothing; and the person's Approve over them keeps the bookkeeping.
@Suite("Unreadable limits and approvals fail closed", .timeLimit(.minutes(1)))
struct FailClosedTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FailClosed-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    // MARK: Limits

    @Test(arguments: ["corrupt", "newer", "permissions"])
    func unreadableLimitsStartNothingAndSaySo(_ how: String) async throws {
        let (locations, work) = try temporary()
        let limits = LimitStore(locations: locations)
        try limits.save(CostLimits(daily: Cost(amount: 5, currency: "USD")))
        let good = try Data(contentsOf: locations.limits)
        let bytes: Data = switch how {
        case "corrupt": Data("<<<<<<< HEAD\n{}\n=======\n".utf8)
        case "newer": Data(#"{"daily":{"credits":5}}"#.utf8)
        default: good
        }
        try bytes.write(to: locations.limits)
        if how == "permissions" {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locations.limits.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locations.limits.path) }

        let launcher = FakeLauncher()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        do {
            _ = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "go"))
            Issue.record("started with unreadable limits")
        } catch let error as JSONRPCError {
            #expect(error.message.contains("spending limits could not be read"))
        }
        #expect(launcher.launchCount == 0)
        #expect(await core.isDayLimitReached(), "workflows and queued prompts hold too")
        #expect(await core.currentCostState().note?.contains("Nothing new starts") == true, "the page says so")

        // The file is kept: in place when it would not read, or set aside byte for byte.
        if how == "permissions" {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locations.limits.path)
            #expect(try Data(contentsOf: locations.limits) == bytes)
        } else {
            #expect(try StoreCoding.asides(of: locations.limits).first.map { try Data(contentsOf: $0) } == bytes)
            // Setting them again opens the gate.
            try limits.save(CostLimits(daily: Cost(amount: 5, currency: "USD")))
            let fresh = LimitStore(locations: locations)
            #expect(!fresh.unreadable)
        }
    }

    // MARK: Approvals

    private func workflowFile(_ locations: StoreLocations, began: Bool) -> Data {
        let folder = locations.root.appendingPathComponent("work").path
        return Data(("{" + (began ? #""approvalsBegan":"2026-10-01T10:00:00Z","# : "")
            + #""runs":[],"states":[{"folder":"file://\#(folder)/","workflowID":"w","approvedDigest":"abc","#
            + #""standingAgentID":"00000000-0000-0000-0000-000000000001","offBy":"file"}]}"#).utf8)
    }

    @Test func approvalsThatLoseTheirBeginningApproveNothing() throws {
        let (locations, _) = try temporary()
        let store = WorkflowStore(locations: locations)
        try workflowFile(locations, began: true).write(to: locations.workflows)
        #expect(store.load().unreadable == false)
        #expect(FileManager.default.fileExists(atPath: ApprovalFile.marker(for: locations.workflows).path),
                "reading a begun file marks it")

        // `{}`: decodes, but approval began here once.
        try Data("{}".utf8).write(to: locations.workflows)
        let empty = store.load()
        #expect(empty.unreadable && empty.approvalsBegan != nil)

        // Deleted to recover: still began.
        try FileManager.default.removeItem(at: locations.workflows)
        let gone = store.load()
        #expect(gone.unreadable && gone.approvalsBegan != nil)
        try store.save(gone)
        #expect(!FileManager.default.fileExists(atPath: locations.workflows.path), "a tick writes nothing")
    }

    @Test func aFileWithNoBeginningAndNoMarkerIsStillTheFirstStart() throws {
        let (locations, _) = try temporary()
        try workflowFile(locations, began: false).write(to: locations.workflows)
        let records = WorkflowStore(locations: locations).load()
        #expect(!records.unreadable && records.approvalsBegan == nil)
    }

    /// The person's Approve over a file that lost `approvalsBegan` salvages the standing
    /// agent and the switch from it, never its approvals, and keeps a copy.
    @Test func theReplacingWriteSalvagesWhatDecoded() throws {
        let (locations, _) = try temporary()
        let store = WorkflowStore(locations: locations)
        try store.save(WorkflowRecords(approvalsBegan: Date()))
        let lost = workflowFile(locations, began: false)
        try lost.write(to: locations.workflows)

        var records = store.load()
        #expect(records.unreadable)
        let state = try #require(records.states.first)
        #expect(state.approvedDigest == nil, "nothing it approved is approved")
        #expect(state.standingAgentID != nil)
        #expect(state.offBy != nil)

        records.states[0].approvedDigest = "new"
        try store.save(records, replacing: true)
        let after = store.load()
        #expect(!after.unreadable && after.approvalsBegan != nil)
        #expect(after.states.first?.standingAgentID == state.standingAgentID)
        #expect(after.states.first?.offBy == state.offBy)
        #expect(after.states.first?.approvedDigest == "new")
        #expect(try StoreCoding.asides(of: locations.workflows).first.map { try Data(contentsOf: $0) } == lost)
    }

    @Test func pluginAndServerApprovalsFailClosedToo() throws {
        let (locations, _) = try temporary()
        let plugins = PluginApprovalStore(file: locations.root.appendingPathComponent("plugin-approvals.json"))
        let servers = MCPApprovalStore(file: locations.root.appendingPathComponent("mcp-approvals.json"))
        try plugins.save(PluginApprovals(approvalsBegan: Date(), approved: ["p": "d"]))
        try servers.save(MCPApprovals(approvalsBegan: Date(), approved: ["s": "d"]))

        try Data(#"{"approved":{"p":"d"}}"#.utf8).write(to: plugins.file)
        try FileManager.default.removeItem(at: servers.file)
        #expect(plugins.load().unreadable && plugins.load().approved.isEmpty)
        #expect(servers.load().unreadable && servers.load().approved.isEmpty)
    }
}
