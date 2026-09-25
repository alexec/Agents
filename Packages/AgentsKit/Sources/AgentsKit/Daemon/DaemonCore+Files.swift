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
