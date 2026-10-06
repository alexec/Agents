import Foundation
import Observation

/// The folders a files tree has read through its host, and the reads on their way.
/// The window's pane and the iPad's tree are drawn from the same reads (#345).
///
/// Each folder ends on its contents or a sentence, never on "Reading…" for good (#62),
/// and a slower earlier read landing after a later one is dropped (#89).
@MainActor
@Observable
public final class FileTreeReads {
    /// Every folder read so far, by `FileTree.key`: the top, and each one opened in the tree.
    public private(set) var listings: [String: DirectoryListing] = [:]
    /// The folders that could not be read, each with the sentence saying why.
    public private(set) var problems: [String: String] = [:]
    /// Folders with a read on its way, so one waiting for its parent is asked for once.
    @ObservationIgnored private var reading: Set<String> = []
    /// Which read of each folder is the current one.
    @ObservationIgnored private var requests: [String: Int] = [:]

    public init() {}

    /// Read a folder. The listing on screen, if any, stays up until the new one is in
    /// hand. `listed` runs once it is, so folders open under it can be read in turn.
    public func read(_ folder: URL, agentID: UUID, files: RemoteFiles,
                     listed: @escaping @MainActor () -> Void = {}) {
        let key = FileTree.key(folder)
        let request = (requests[key] ?? 0) + 1
        requests[key] = request
        reading.insert(key)
        Task {
            let read: Result<DirectoryListing, any Error>
            do { read = .success(try await files.list(agentID: agentID, folder: folder)) }
            catch { read = .failure(error) }
            // The later read always ends, with a listing or a sentence: `RemoteFiles`
            // gives up on a read nobody answers.
            guard request == requests[key] else { return }
            reading.remove(key)
            switch read {
            case .success(let fresh):
                if listings[key] != fresh { listings[key] = fresh }
                problems[key] = nil
                listed()
            case .failure(let error):
                listings[key] = nil
                problems[key] = RemoteFiles.describe(error, name: folder.lastPathComponent)
            }
        }
    }

    /// Every open folder on screen that has nothing to show and no read on its way: one
    /// opened before its parent had been read, as when the pane is drawn afresh with
    /// folders still open, or a file deep in the tree is revealed (#62).
    public func unread(root: URL, expanded: Set<String>) -> [URL] {
        FileTree.unread(root: root, expanded: expanded, listings: listings,
                        problems: Set(problems.keys), reading: reading)
    }

    /// The tree's lines, from what has been read so far.
    public func lines(root: URL, expanded: Set<String>) -> [FileTree.Line] {
        FileTree.lines(root: root, expanded: expanded, listings: listings, problems: problems)
    }

    /// The folders on screen: the top, and every open one whose parents are open too.
    /// Only these are read again when the disk changes.
    public func visibleFolders(root: URL, expanded: Set<String>) -> [URL] {
        FileTree.visibleFolders(root: root, expanded: expanded, listings: listings)
    }

    /// The pane is somewhere else now (the agent moved): nothing read is kept.
    public func forget() {
        listings = [:]
        problems = [:]
        reading = []
    }
}
