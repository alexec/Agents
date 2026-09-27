import Foundation

/// Project MCP approval lives beside plugin approval: outside the project, begun once
/// (060, R6). Listing and Approve are control-only methods on `DaemonCore+MCPCatalog`.
extension DaemonCore {
    var mcpApprovalStore: MCPApprovalStore {
        MCPApprovalStore(file: locations.root.appending(path: "mcp-approvals.json"))
    }

    /// The first start with approval: every project server already on disk is approved
    /// as it stands. Once only, however many restarts.
    func beginMCPApprovalsIfNeeded() {
        var records = mcpApprovalStore.load()
        guard records.approvalsBegan == nil else { return }
        for project in allProjects(includeArchived: true) where project.exists {
            records.stampExisting(in: project.folder)
        }
        records.approvalsBegan = Date()
        do {
            try mcpApprovalStore.save(records)
        } catch {
            DaemonLog.shared.write("mcp: could not begin approvals")
        }
    }
}
