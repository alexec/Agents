import Foundation

/// An agent's folder, read for a device (034).
///
/// The Mac's panes read the disk themselves, in the window's own process. A phone has
/// no disk to read, so these are the same readers — `DirectoryReader`, `FileProbe`,
/// `FolderWatch` — run here and carried over the connection it already has. They only
/// read. The one write a device may make is `artifact/write`, and that is 022's.
///
/// Held to the agent's folders, and refused with the sentence `show_file` and
/// `artifact/write` use: one rule, said one way, whichever door it is met at.
extension DaemonCore {
    /// One connection's interest in one agent's folders, under one watched root.
    struct FileInterest: Hashable, Sendable {
        var agentID: UUID
        var root: URL
    }

    // MARK: Reading

    public func listFiles(_ request: DaemonAPI.FilesListRequest) throws -> DirectoryListing {
        let (url, _) = try resolveInScope(agentID: request.agentID, path: request.folder)
        do {
            return try DirectoryReader.read(url)
        } catch DirectoryReader.Failure.notADirectory {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That is a file.")
        } catch DirectoryReader.Failure.notReadable {
            throw Self.notReadable(url)
        } catch {
            throw Self.gone(url)
        }
    }

    /// Any folder this account can read, by absolute path (037). Only ever asked by a
    /// window choosing a server folder as a project, before there is an agent to scope
    /// a listing to. The daemon runs as the person, so it shows exactly what they could
    /// `ls` themselves, and no more.
    public func browse(_ request: DaemonAPI.FilesBrowseRequest) throws -> DirectoryListing {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        var path = request.path ?? "~"
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard path.hasPrefix("/") else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Give an absolute path, or one starting ~.")
        }
        let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        do {
            return try DirectoryReader.read(url)
        } catch DirectoryReader.Failure.notADirectory {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That is a file.")
        } catch DirectoryReader.Failure.notReadable {
            throw Self.notReadable(url)
        } catch {
            throw Self.gone(url)
        }
    }

    /// Keep a file attached on another machine where this agent can read it (037):
    /// `<its folder>/.agents/attachments/<uuid>-<name>`, private to the account. The
    /// name is reduced to its last component so it can never climb out of there.
    public func writeAttachment(_ request: DaemonAPI.FilesWriteRequest) throws -> DaemonAPI.FilesWriteResponse {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard request.data.count <= DaemonAPI.attachmentLimit else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That file is too big to send.")
        }
        let name = URL(filePath: request.name).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That file has no name.")
        }
        let folder = agent.cwd.appendingPathComponent(".agents/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)")
        try request.data.write(to: file, options: .atomic)
        return DaemonAPI.FilesWriteResponse(path: file.path(percentEncoded: false))
    }

    public func readFile(_ request: DaemonAPI.FilesReadRequest) throws -> FileReading {
        let (url, _) = try resolveInScope(agentID: request.agentID, path: request.path)
        do {
            return try FileReading.read(url, known: request.knownStamp)
        } catch FileProbe.Failure.isDirectory {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That is a folder.")
        } catch FileProbe.Failure.notReadable {
            throw Self.notReadable(url)
        } catch {
            throw Self.gone(url)
        }
    }

    // MARK: Watching

    public func watchFiles(_ request: DaemonAPI.FilesWatchRequest, connection: UUID?) throws {
        guard let connection else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Only a connection can watch.")
        }
        let (_, root) = try resolveInScope(agentID: request.agentID, path: request.folder)
        guard FileManager.default.fileExists(atPath: root.path) else { throw Self.gone(root) }
        fileInterests[connection, default: []].insert(FileInterest(agentID: request.agentID, root: root))
        startWatching(root)
    }

    public func unwatchFiles(_ request: DaemonAPI.FilesWatchRequest, connection: UUID?) {
        guard let connection,
              let (_, root) = try? resolveInScope(agentID: request.agentID, path: request.folder) else { return }
        fileInterests[connection]?.remove(FileInterest(agentID: request.agentID, root: root))
        if fileInterests[connection]?.isEmpty == true { fileInterests[connection] = nil }
        stopWatchingIfUnwanted(root)
    }

    /// A connection has gone: everything it was watching goes with it. A phone leaves
    /// without saying so as often as not, and an FSEvents stream left running for it
    /// would run for the rest of the daemon's life.
    public func connectionEnded(_ connection: UUID) {
        forgetShellWatcher(connection)
        guard let interests = fileInterests.removeValue(forKey: connection) else { return }
        for root in Set(interests.map(\.root)) { stopWatchingIfUnwanted(root) }
    }

    /// How many folder watches are running. For the tests: an interest that ends must
    /// take its watch with it.
    var fileWatchCount: Int { fileWatches.count }

    private func startWatching(_ root: URL) {
        guard fileWatches[root] == nil else { return }
        fileWatches[root] = FolderWatch(root: root) { [weak self] folders in
            Task { await self?.filesChanged(under: root, folders: folders) }
        }
    }

    private func stopWatchingIfUnwanted(_ root: URL) {
        let wanted = fileInterests.values.contains { $0.contains { $0.root == root } }
        guard !wanted, let watch = fileWatches.removeValue(forKey: root) else { return }
        watch.stop()
    }

    /// Something changed under a root: told to each connection watching it, once per
    /// agent it is watching it for.
    func filesChanged(under root: URL, folders: [URL]) {
        var byAgent: [UUID: Set<UUID>] = [:]
        for (connection, interests) in fileInterests {
            for interest in interests where interest.root == root {
                byAgent[interest.agentID, default: []].insert(connection)
            }
        }
        let paths = folders.map { $0.standardizedFileURL.path }
        for (agentID, connections) in byAgent {
            send(DaemonAPI.Notification.filesChanged,
                 DaemonAPI.FilesChangedNotification(agentID: agentID, folders: paths),
                 to: { connections.contains($0.id) })
        }
    }

    // MARK: The boundary

    /// The path as it really is, and the folder of the agent's that holds it.
    ///
    /// Resolved before it is judged, and the resolved path is what is read: a link
    /// inside the folder that points out of it is refused, not followed. The Mac's
    /// own pane runs as the person, who could read the target anyway; a device is a
    /// door onto the Mac, and holds to the folders the agent was given.
    func resolveInScope(agentID: UUID, path: String) throws -> (url: URL, root: URL) {
        guard let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard path.hasPrefix("/") else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "The path has to be absolute, starting at `/`.")
        }
        let scope = agent.folderScope
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        // The runtime's own plan, shown to be read, and nothing else beside it.
        if isShownPlan(url, for: agentID) { return (url, url.deletingLastPathComponent()) }
        guard scope.allows(url.path) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: scope.refusal(for: path))
        }
        let root = scope.folders.first { FolderScope(folders: [$0]).allows(url.path) } ?? agent.cwd
        return (url, root.standardizedFileURL)
    }

    private static func gone(_ url: URL) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.fileGone, message: "\(url.lastPathComponent) is gone.")
    }

    private static func notReadable(_ url: URL) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.fileNotReadable,
                     message: "\(url.lastPathComponent) can't be opened.")
    }
}
