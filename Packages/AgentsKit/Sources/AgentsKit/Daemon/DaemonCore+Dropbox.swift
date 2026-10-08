import Foundation
import AgentsKitCore

/// What a file in a drop box looked like: enough to tell it arrived, was replaced, or is
/// still being written.
struct DropboxStamp: Hashable, Sendable {
    var size: Int64
    var modified: Date?
    /// The inode, so a file replaced by one of the same size in the same second is new.
    var file: UInt64
}

/// A drop box per project (#231): `<project>/.agents/dropbox/`, and any folder in it.
///
/// A file arriving there raises `dropbox.file_added`, once, when it has stopped growing.
/// What was there when the project was first watched is only seeded: arrivals fire, not
/// what was already waiting. The daemon never moves or deletes a dropped file; what
/// happens to it is the workflow's agent's to decide. A file replaced under the same name,
/// or changed where it lies, has arrived again and fires again.
///
/// It hangs off the project's one watch (#173), which hears the drop box like any other
/// folder under `.agents`. Names starting with a dot are passed over: they are what a
/// copy writes before it renames the file into place, and Finder's `.DS_Store`.
extension DaemonCore {
    /// How long a file must stay as it is before it counts as arrived.
    static let dropboxSettle: Duration = .milliseconds(600)

    static func dropboxFolder(in project: URL) -> URL {
        project.appending(path: ".agents/dropbox", directoryHint: .isDirectory)
    }

    /// Take what is in a project's drop box now as already there. Once per watch: a watch
    /// started again, without the folders it leaves out, keeps what it had seen.
    func seedDropbox(in folder: URL) {
        guard dropboxSeen[folder] == nil else { return }
        dropboxSeen[folder] = Self.dropboxFiles(in: folder)
    }

    func stopWatchingDropbox(in folder: URL) {
        dropboxSeen.removeValue(forKey: folder)
        dropboxSettling.removeValue(forKey: folder)
        dropboxChecks.removeValue(forKey: folder)?.cancel()
    }

    /// Whether a change the project's watch heard is in, or could have made, the drop box.
    /// The project's top and `.agents` are named when the drop box is made with a file in
    /// it at once; they change for much else too, so they count only once it is there.
    static func touchesDropbox(_ changed: [URL], in folder: URL) -> Bool {
        let agents = folder.appending(path: ".agents").path
        let dropbox = dropboxFolder(in: folder).path
        if changed.contains(where: { $0.path == dropbox || $0.path.hasPrefix(dropbox + "/") }) { return true }
        return changed.contains { $0.path == folder.path || $0.path == agents }
            && isDirectory(dropboxFolder(in: folder))
    }

    /// Look once the drop box has been still for a moment. A file being written keeps
    /// moving this on, so it is looked at after it stops.
    func scheduleDropboxCheck(in folder: URL) {
        guard dropboxSeen[folder] != nil else { return }
        dropboxChecks[folder]?.cancel()
        dropboxChecks[folder] = Task { [weak self] in
            try? await Task.sleep(for: Self.dropboxSettle)
            guard !Task.isCancelled else { return }
            await self?.checkDropbox(in: folder)
        }
    }

    /// Compare the drop box with what was last seen. A file new or changed since is
    /// announced when this look finds it as the last one did; until then it is settling,
    /// and another look is due.
    func checkDropbox(in folder: URL) {
        dropboxChecks[folder] = nil
        guard var seen = dropboxSeen[folder] else { return }
        let settling = dropboxSettling[folder] ?? [:]
        let now = Self.dropboxFiles(in: folder)
        var stillSettling: [String: DropboxStamp] = [:]
        var arrived: [(String, DropboxStamp)] = []
        for (path, stamp) in now where seen[path] != stamp {
            if settling[path] == stamp { arrived.append((path, stamp)) } else { stillSettling[path] = stamp }
        }
        for path in seen.keys where now[path] == nil { seen[path] = nil }
        for (path, stamp) in arrived { seen[path] = stamp }
        dropboxSeen[folder] = seen
        dropboxSettling[folder] = stillSettling.isEmpty ? nil : stillSettling
        for (path, stamp) in arrived.sorted(by: { $0.0 < $1.0 }) {
            raiseDropboxArrival(path, stamp: stamp, in: folder)
        }
        if !stillSettling.isEmpty { scheduleDropboxCheck(in: folder) }
    }

    private func raiseDropboxArrival(_ relative: String, stamp: DropboxStamp, in folder: URL) {
        let file = Self.dropboxFolder(in: folder).appending(path: relative)
        let name = file.lastPathComponent
        let inside = relative.contains("/") ? String(relative[..<relative.lastIndex(of: "/")!]) : ""
        let place = inside.isEmpty ? "the drop box" : "dropbox/\(inside)"
        raise(EventDraft(name: "dropbox.file_added", at: now(), scope: .project(folder: folder),
                         sentence: "\(name) arrived in \(place).",
                         details: ["path": file.path(percentEncoded: false), "name": name, "folder": inside,
                                   "extension": file.pathExtension.lowercased(), "size": String(stamp.size)]))
    }

    /// Every file in a project's drop box, by its path inside it. Folders are not files,
    /// and neither is anything whose name starts with a dot.
    static func dropboxFiles(in folder: URL) -> [String: DropboxStamp] {
        let root = dropboxFolder(in: folder)
        guard isDirectory(root) else { return [:] }
        let base = root.standardizedFileURL.path
        var files: [String: DropboxStamp] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/"),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            files[String(path.dropFirst(base.count + 1))] = DropboxStamp(
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attributes[.modificationDate] as? Date,
                file: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
        }
        return files
    }

    // MARK: Putting a file in

    /// `dropbox/put`: a file from a window, a phone or a page, written into a project's
    /// drop box. Written beside its place under a hidden name and renamed into it, so the
    /// watch sees it arrive whole; one already there by that name is replaced, and fires
    /// again.
    public func putInDropbox(_ request: DaemonAPI.DropboxPutRequest) throws -> DaemonAPI.DropboxPutResponse {
        let project = Project.standardize(request.folder)
        guard projectWatches[project] != nil else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That is not a project here.")
        }
        guard request.data.count <= DaemonAPI.dropboxPutLimit else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "That file is too big to send. Copy it into .agents/dropbox/ on its host instead.")
        }
        let name = URL(filePath: request.name).lastPathComponent
        guard !name.isEmpty, name != "/", !name.hasPrefix(".") else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "A drop box file needs a name that does not start with a dot.")
        }
        let parts = (request.subfolder ?? "").split(separator: "/").map(String.init)
        guard parts.allSatisfy({ !$0.hasPrefix(".") }) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "A folder in the drop box cannot start with a dot.")
        }
        var target = Self.dropboxFolder(in: project)
        for part in parts { target.append(path: part, directoryHint: .isDirectory) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appending(path: name)
        let staging = target.appending(path: ".\(name).\(UUID().uuidString.prefix(8)).part")
        try request.data.write(to: staging)
        guard rename(staging.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw JSONRPCError(code: DaemonAPI.Failure.couldNotSave, message: "The file could not be put in the drop box.")
        }
        return DaemonAPI.DropboxPutResponse(path: file.path(percentEncoded: false))
    }
}
