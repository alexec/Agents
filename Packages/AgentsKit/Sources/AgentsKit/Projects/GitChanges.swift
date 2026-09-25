import Foundation

/// Asking git what changed, without touching the repository (035 research R4).
///
/// An agent may be committing in the same repository at the same moment, so nothing
/// here may take a lock it could collide with or write an index it did not ask for.
/// `git status` is the command that quietly refreshes the index; `GIT_OPTIONAL_LOCKS=0`
/// is git's own switch for a reader that must not, and every command here runs with it.
public enum GitChanges {
    /// Laid over `GitProcess`'s environment for every command here.
    static let readOnly = ["GIT_OPTIONAL_LOCKS": "0"]

    /// The repository and the commit a folder is on, or nil when it is not in a
    /// repository, the repository has no commits, or git is not there. Never throws:
    /// an agent starts whether or not its changes can be measured.
    public static func startingPoint(of folder: URL) async -> StartingPoint? {
        guard let git = try? GitProcess(["rev-parse", "--show-toplevel", "HEAD"], in: folder,
                                        environment: readOnly),
              let outcome = try? await git.run(), outcome.succeeded else { return nil }
        let lines = outcome.output.split(separator: "\n").map(String.init)
        guard lines.count == 2, lines[1].count >= 40 else { return nil }
        return StartingPoint(repository: URL(filePath: lines[0], directoryHint: .isDirectory),
                             commit: lines[1])
    }
}
