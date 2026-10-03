import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An approvals file that cannot be read approves nothing (#169).
///
/// What this holds: a workflows, plugin or MCP approvals file that is there and does not
/// decode is not "approval has not begun". Everything waits for the person, the pages
/// say why, and the file is left byte for byte until the person's own Approve replaces
/// it, keeping a `.corrupt-<date>` copy of the old one beside it.
@Suite("Unreadable approvals approve nothing", .timeLimit(.minutes(1)))
struct UnreadableApprovalsTests {
    private let fileManager = FileManager.default
    /// What a write that stopped part way through leaves.
    private let torn = Data(#"{"approvalsBegan":"2026-09-01T00:00:00Z","states":[{"folder":"file:///"#.utf8)

    private func temporary() throws -> (StoreLocations, URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UnreadableApprovals-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let home = base.appending(path: "home", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        var locations = StoreLocations(root: base.appending(path: "store", directoryHint: .isDirectory))
        locations.personalHome = home
        try fileManager.createDirectory(at: locations.root, withIntermediateDirectories: true)
        return (locations, base)
    }

    private func project(_ base: URL) throws -> URL {
        let url = base.appending(path: "work", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func writeWorkflow(_ id: String, in work: URL) throws {
        try fileManager.createDirectory(at: WorkflowFile.folder(in: work), withIntermediateDirectories: true)
        try Data("""
            ---
            on:
              - schedule:
                  at: [":00"]
            agent: new
            ---

            Push to production.
            """.utf8).write(to: WorkflowFile.url(for: id, in: work))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private func corruptCopies(of url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") }
    }

    // MARK: Workflows

    @Test func anUnreadableWorkflowsFileApprovesNothingAndIsLeftAlone() async throws {
        let (locations, base) = try temporary()
        let work = try project(base)
        try writeWorkflow("deploy", in: work)
        try torn.write(to: locations.workflows)

        let core = try await core(locations)
        _ = try await core.addProject(work)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        await core.tickWorkflows(now: Date().addingTimeInterval(3600))

        let summary = try #require(await core.allWorkflows(in: work).first { $0.workflowID == "deploy" })
        let waiting = try #require(summary.awaitingApproval, "a file present at start is not approved from a file that could not be read")
        #expect(waiting.note?.contains("workflows.json could not be read") == true)
        let ran = try await core.runWorkflow(.init(folder: work, workflowID: "deploy"))
        #expect(await core.allAgents().isEmpty, "nothing started")
        // The refusal is not recorded either: recording it would be a write over the file.
        if case .ran = ran.lastOutcome { Issue.record("it ran") }
        #expect(try Data(contentsOf: locations.workflows) == torn, "begin, tick and fire wrote nothing over it")
        #expect(try corruptCopies(of: locations.workflows).isEmpty)

        // The person's Approve replaces it, keeping the old one beside it.
        let approved = try await core.approveWorkflow(.init(folder: work, workflowID: "deploy", digest: waiting.digest))
        #expect(approved.awaitingApproval == nil)
        let copies = try corruptCopies(of: locations.workflows)
        #expect(copies.count == 1)
        #expect(try copies.first.map { try Data(contentsOf: $0) } == torn)
        let records = WorkflowStore(locations: locations).load()
        #expect(!records.unreadable)
        #expect(records.approvalsBegan != nil, "still begun, so nothing new is approved by a restart")
    }

    /// One state an older build cannot decode costs that state, not the file.
    @Test func oneStateThatWillNotDecodeCostsOnlyThatState() throws {
        let json = """
            {"approvalsBegan":"2026-09-01T00:00:00Z","states":[
              {"folder":42,"workflowID":"broken"},
              {"folder":"file:///tmp/work/","workflowID":"tests","approvedDigest":"abc"}
            ]}
            """
        let records = try StoreCoding.decoder.decode(WorkflowRecords.self, from: Data(json.utf8))
        #expect(records.states.map(\.workflowID) == ["tests"])
        #expect(records.approvalsBegan != nil)
    }

    @Test func aMissingWorkflowsFileIsStillTheFirstStart() throws {
        let (locations, _) = try temporary()
        let records = WorkflowStore(locations: locations).load()
        #expect(records.approvalsBegan == nil)
        #expect(!records.unreadable)
    }

    // MARK: Plugins

    @Test func anUnreadablePluginApprovalsFileApprovesNoPlugin() async throws {
        let (locations, base) = try temporary()
        let work = try project(base)
        let plugin = work.appending(path: ".agents/plugins/deploy")
        try fileManager.createDirectory(at: plugin.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
        try #"{"name":"deploy","version":"1.0.0"}"#
            .write(to: plugin.appending(path: ".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
        let garbage = Data("not json".utf8)
        try garbage.write(to: locations.pluginApprovals)

        let core = try await core(locations)
        _ = try await core.addProject(work)
        await core.startWorkflows()

        let listed = try #require(await core.projectPlugins(in: work).first)
        let waiting = try #require(listed.awaitingApproval)
        #expect(waiting.note?.contains("plugin-approvals.json could not be read") == true)
        #expect(await core.approvedPluginFolders(for: work).isEmpty)
        #expect(try Data(contentsOf: locations.pluginApprovals) == garbage)

        _ = try await core.approvePlugin(.init(plugin: listed.folder, digest: waiting.digest))
        #expect(await core.approvedPluginFolders(for: work).count == 1)
        let copies = try corruptCopies(of: locations.pluginApprovals)
        #expect(try copies.first.map { try Data(contentsOf: $0) } == garbage)
    }

    // MARK: MCP servers

    @Test func anUnreadableMCPApprovalsFileApprovesNoServer() throws {
        let (locations, base) = try temporary()
        let work = try project(base)
        let file = locations.root.appending(path: "mcp-approvals.json")
        let garbage = Data(#"{"approvalsBegan":"#.utf8)
        try garbage.write(to: file)
        let store = MCPApprovalStore(file: file)
        let entry = OrderedJSON.object([("url", .string("https://example")), ("type", .string("http"))])

        var records = store.load()
        #expect(records.unreadable)
        #expect(!records.isApproved(folder: work, name: "remote", entry: entry))

        // A write nobody asked for leaves it; the person's own replaces it with a copy kept.
        try store.save(records)
        #expect(try Data(contentsOf: file) == garbage)
        records.recordAdded(folder: work, name: "remote", entry: entry)
        try store.save(records, replacing: true)
        #expect(store.load().isApproved(folder: work, name: "remote", entry: entry))
        let copies = try corruptCopies(of: file)
        #expect(try copies.first.map { try Data(contentsOf: $0) } == garbage)
    }

    // MARK: The log

    @Test func anUnreadableFileIsLoggedOncePerVersion() throws {
        let (locations, _) = try temporary()
        try torn.write(to: locations.workflows)
        let log = UnreadableLog()
        #expect(log.note(locations.workflows))
        #expect(!log.note(locations.workflows), "read again, not said again")
        try Data("still not json, and longer".utf8).write(to: locations.workflows)
        #expect(log.note(locations.workflows), "a different broken file is said")
    }
}
