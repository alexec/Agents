import Foundation

/// One plugin in a folder's `.agents/plugins`, as the folder page shows it (security
/// review, S2).
///
/// A plugin can carry hooks and MCP servers, which a runtime runs by itself when a session
/// starts, so a plugin folder is a way to run commands as surely as a workflow file is.
/// It arrives by the same roads — an agent's edit, a `git pull`, a branch, a clone — and
/// waits for the person's OK the same way: on its content, by digest.
public struct FolderPlugin: Codable, Hashable, Sendable, Identifiable {
    /// The folder it is in.
    public var folderPath: URL
    /// The plugin's folder, `<folder>/.agents/plugins/<name>`, as listed rather than
    /// resolved: what the approval is kept against.
    public var folder: URL
    public var name: String
    /// What the plugin brings that runs or reaches a runtime by itself, read off its files:
    /// `hooks`, `MCP servers`, `skills`, `commands`, `agents`. For the row, so the person
    /// knows what they are saying yes to.
    public var carries: [String]
    /// Nil when the folder is the one approved. The same shape a workflow's is: the digest
    /// is what Approve sends back, so only what was shown is approved.
    public var awaitingApproval: WorkflowApproval?

    public var id: URL { folder }

    public init(folderPath: URL, folder: URL, name: String, carries: [String], awaitingApproval: WorkflowApproval?) {
        self.folderPath = folderPath
        self.folder = folder
        self.name = name
        self.carries = carries
        self.awaitingApproval = awaitingApproval
    }
}
