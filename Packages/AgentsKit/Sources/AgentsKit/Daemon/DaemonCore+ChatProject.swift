import Foundation
import AgentsKitCore

/// The chat project (#229): `~/.agents/chat`, made by each host's daemon for the person,
/// so a chat is an ordinary session in a project nobody had to pick. Its folder is the
/// one every chat works in, and so the place a chat keeps what a later one should find.
///
/// Made once. After that it is the person's like any project: archived stays archived,
/// and its files and `AGENTS.md` are never touched again.
extension DaemonCore {
    /// At start, before recovery, so it is listed before any client asks.
    ///
    /// Nothing on a root with no personal home. Nothing when a record of it exists, live
    /// or archived, except a live one whose folder has gone, which gets the folder back
    /// empty (its record says it was laid out, so nothing is laid out again).
    func ensureChatProject() {
        chatProjectFailure = nil
        guard let folder = chatProjectFolder() else { return }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let there = fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        if there, !isDirectory.boolValue {
            chatProjectFailed("\(folder.path) is a file, so there is no chat project.")
            return
        }
        let record = projectRecords()[folder]
        if record?.isArchived == true { return }
        if !there {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                chatProjectFailed("\(folder.path) could not be made: \(error.localizedDescription)")
                return
            }
            DaemonLog.shared.write("chat project: made \(folder.path)")
        }
        guard record == nil else { return }
        layOutOnce(folder, chat: true)
        if projectRecords()[folder] == nil {
            chatProjectFailed("\(folder.path) could not be recorded as a project.")
        } else {
            DaemonLog.shared.write("chat project: laid out \(folder.path)")
        }
    }

    /// For `projects/chatState`: worked out from the record and the disk as they are now,
    /// so an archive or unarchive since start answers at once.
    func chatProjectState() -> DaemonAPI.ChatProjectState {
        guard let folder = chatProjectFolder() else { return .noPersonalHome }
        if let record = projectRecords()[folder] {
            if record.isArchived { return .archived(folder: folder) }
            if Self.isDirectory(folder) { return .ready(folder: folder) }
        }
        return .failed(message: chatProjectFailure ?? "\(folder.path) is not there. It is made again when this host's daemon starts.")
    }

    /// Whether this folder is this host's chat project, for the `isChat` mark.
    func isChatProject(_ folder: URL) -> Bool {
        chatProjectFolder() == folder
    }

    /// The chat folder in the one form a project's folder is in. Resolved through the home,
    /// which is there, rather than the folder, which may not be yet: a path that does not
    /// exist keeps its symlinks, so `/var/…/chat` before it is made and `/private/var/…/chat`
    /// after would be two projects.
    func chatProjectFolder() -> URL? {
        guard let home = locations.personalHome else { return nil }
        return Project.standardize(Project.standardize(home).appending(path: ".agents/chat"))
    }

    private func chatProjectFailed(_ sentence: String) {
        chatProjectFailure = sentence
        DaemonLog.shared.write("chat project: \(sentence)")
    }
}
