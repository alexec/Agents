import AgentsKitCore
import Foundation

/// Nothing from a project plugin reaches a runtime until the person has approved it
/// (security review, S2).
///
/// A plugin in `.agents/plugins` can carry hooks and MCP servers, and a runtime runs them
/// by itself when a session starts: an agent allowed only to edit files, a `git pull`, a
/// branch or a clone could otherwise put commands there that run with nobody asked. So a
/// plugin is handled as a workflow file is (`DaemonCore+WorkflowApproval.swift`): a digest
/// of its folder is kept here, outside the project, and a plugin that no longer matches is
/// left out of every session — Claude's and Grok's `_meta`, the marketplace index, Gemini's
/// extension links — until the person approves it on the project page.
///
/// Checked on every session, not once: Gemini's links and a marketplace's plugins are read
/// in place, so a plugin changed after its approval must drop out at the next session.
///
/// Two roads approve without a click, both the person's own: every plugin present when
/// approval began, and Approve itself. The person's own plugins in `~/.agents/plugins` are
/// not asked about: that folder is theirs, not a project's.
extension DaemonCore {
    var pluginApprovalStore: PluginApprovalStore { PluginApprovalStore(file: locations.pluginApprovals) }

    /// The key a plugin's approval is kept under: its folder as listed, standardized.
    static func pluginKey(_ plugin: URL) -> String { plugin.standardizedFileURL.path }

    /// What `plugin` is waiting on, or nil when its folder is the one approved. Nothing
    /// waits before approval has begun.
    func pluginAwaitingApproval(_ plugin: URL, records: PluginApprovals) -> WorkflowApproval? {
        guard records.approvalsBegan != nil, let digest = DotAgents.pluginDigest(plugin) else { return nil }
        let approved = records.approved[Self.pluginKey(plugin)]
        guard digest != approved else { return nil }
        return WorkflowApproval(digest: digest, isNew: approved == nil)
    }

    /// The first start with approval: every plugin already in a project is approved as it
    /// stands. Once only, however many restarts.
    func beginPluginApprovalsIfNeeded() {
        var records = pluginApprovalStore.load()
        guard records.approvalsBegan == nil else { return }
        for project in allProjects(includeArchived: true) where project.exists {
            for plugin in DotAgents.pluginFolders(for: project.folder) {
                guard let digest = DotAgents.pluginDigest(plugin) else { continue }
                records.approved[Self.pluginKey(plugin)] = digest
            }
        }
        records.approvalsBegan = Date()
        pluginApprovalStore.save(records)
    }

    /// Every plugin in the project `folder` belongs to, approved or waiting.
    public func projectPlugins(in folder: URL) -> [ProjectPlugin] {
        let records = pluginApprovalStore.load()
        let project = DotAgents.projectFolder(for: folder)
        return DotAgents.pluginFolders(for: folder).map { plugin in
            ProjectPlugin(project: project, folder: plugin, name: plugin.lastPathComponent,
                          carries: DotAgents.pluginCarries(plugin),
                          awaitingApproval: pluginAwaitingApproval(plugin, records: records))
        }
    }

    /// The plugins a session in `cwd` may be handed: the approved ones. When any is left
    /// out, the log says which, and every window hears the project's list, so its row says
    /// it is waiting.
    func approvedPluginFolders(for cwd: URL) -> [URL] {
        let records = pluginApprovalStore.load()
        var approved: [URL] = []
        var waiting: [String] = []
        for plugin in DotAgents.pluginFolders(for: cwd) {
            if pluginAwaitingApproval(plugin, records: records) == nil {
                approved.append(plugin)
            } else {
                waiting.append(plugin.lastPathComponent)
            }
        }
        if !waiting.isEmpty {
            let project = DotAgents.projectFolder(for: cwd)
            DaemonLog.shared.write("plugins: left \(waiting.joined(separator: ", ")) out of a session in \(project.path): waiting for approval")
            broadcast(DaemonAPI.Notification.pluginsChanged,
                      DaemonAPI.PluginsList(folder: project, plugins: projectPlugins(in: project)))
        }
        return approved
    }

    /// The person's Approve. Only the folder they were shown: if it has changed since,
    /// nothing is approved and they are told.
    public func approvePlugin(_ request: DaemonAPI.PluginApproveRequest) throws -> DaemonAPI.PluginsList {
        let plugin = request.plugin.standardizedFileURL
        // `<project>/.agents/plugins/<name>`, three folders up.
        let project = plugin.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard plugin.deletingLastPathComponent().path.hasSuffix("/\(DotAgents.folder)/\(DotAgents.plugins)"),
              DotAgents.pluginFolders(for: project).contains(where: { Self.pluginKey($0) == Self.pluginKey(plugin) }) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "\(plugin.lastPathComponent) is not a plugin in a project's .agents/plugins.")
        }
        guard DotAgents.pluginDigest(plugin) == request.digest else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "\(plugin.lastPathComponent) changed after you looked at it, so it was not approved. Look again.")
        }
        var records = pluginApprovalStore.load()
        records.approved[Self.pluginKey(plugin)] = request.digest
        pluginApprovalStore.save(records)
        DaemonLog.shared.write("plugins: \(plugin.lastPathComponent) in \(project.path) approved")
        let list = DaemonAPI.PluginsList(folder: project, plugins: projectPlugins(in: project))
        broadcast(DaemonAPI.Notification.pluginsChanged, list)
        return list
    }
}
