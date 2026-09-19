import Foundation

/// The workflows a project has.
///
/// One folder, `.agents/workflows`, and nothing outside it. That is what stops anything
/// else in a repository from accidentally becoming a thing that starts agents, and it
/// is the boundary the tool an agent calls is held to.
public enum WorkflowFolder {
    /// Every workflow in a project, including the ones that could not be read.
    ///
    /// A file we cannot parse still comes back, carrying its problem. Leaving it out
    /// would put a gap on the project page where a row should be, and a gap is exactly
    /// how this feature fails quietly.
    public static func workflows(in project: URL) -> [Workflow] {
        let folder = WorkflowFile.folder(in: project)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".\(WorkflowFile.fileExtension)") && !$0.hasPrefix(".") }
            .sorted()
            .map { WorkflowFile.read(folder.appending(path: $0), in: project) }
    }

    /// Whether a path is inside a project's workflow folder.
    ///
    /// Compared after standardising both, so `..` and a symlink cannot walk out of it.
    /// This is the check the tool an agent calls is refused by.
    public static func contains(_ url: URL, project: URL) -> Bool {
        let folder = Project.standardize(WorkflowFile.folder(in: project)).path
        let candidate = Project.standardize(url).path
        return candidate.hasPrefix(folder + "/")
    }

    /// Whether a name could be a workflow's, which is to say whether it is one path
    /// component and not a way out of the folder.
    public static func isValidID(_ workflowID: String) -> Bool {
        guard !workflowID.isEmpty, workflowID.count <= 200 else { return false }
        guard !workflowID.hasPrefix(".") else { return false }
        return !workflowID.contains("/") && !workflowID.contains("\\") && workflowID != ".."
    }
}
