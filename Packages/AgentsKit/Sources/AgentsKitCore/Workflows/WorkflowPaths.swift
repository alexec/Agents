import Foundation

/// Where a project keeps its workflows (the paths only, so the sandboxed window can name
/// a workflow's file without the parser, 058 S5). `WorkflowFile` reads them.
public enum WorkflowPaths {
    public static let fileExtension = "md"
    /// Where a project keeps them. One folder, so nothing else in a repository can
    /// accidentally become a thing that starts agents.
    public static let folderName = ".agents/workflows"

    public static func folder(in project: URL) -> URL {
        project.appending(path: folderName, directoryHint: .isDirectory)
    }

    public static func url(for workflowID: String, in project: URL) -> URL {
        folder(in: project).appending(path: "\(workflowID).\(fileExtension)")
    }
}
