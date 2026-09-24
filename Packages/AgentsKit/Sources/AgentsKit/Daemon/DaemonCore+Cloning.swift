import Foundation

/// A project from a Git URL (027).
///
/// The clone is made in a staging folder inside the daemon's own root and moved into
/// the home folder only once it is whole. Nothing half-made is ever where the person
/// keeps their work, so every way a clone can end badly — git failing, the daemon
/// stopping, the Mac losing power — is cleaned up by deleting the staging folder.
///
/// What it becomes is an ordinary project, added through `addProject` like any folder
/// chosen with the picker. Nothing afterwards knows it was cloned.
extension DaemonCore {
    struct RunningClone {
        var summary: DaemonAPI.CloneSummary
        var process: GitProcess?
    }

    public static func defaultCloneParent(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let named = environment["AGENTS_CLONE_PARENT"], !named.isEmpty {
            return URL(filePath: (named as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var cloneStaging: URL { locations.root.appending(path: "Clones", directoryHint: .isDirectory) }

    /// Tests only.
    func setCloneParent(_ folder: URL, rewrite: (@Sendable (String) -> String)? = nil) {
        cloneParent = folder
        cloneURLRewrite = rewrite
    }

    public func clearCloneStaging() {
        try? FileManager.default.removeItem(at: cloneStaging)
    }

    public func allClones() -> [DaemonAPI.CloneSummary] {
        clones.values.map(\.summary).sorted { $0.startedAt < $1.startedAt }
    }

    /// Clone it and add it, or add the checkout that is already there.
    public func cloneProject(_ text: String) async throws -> DaemonAPI.ProjectSummary {
        guard let remote = GitRemote(text) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notACloneURL,
                               message: "That is not a Git URL this app can clone. Paste an HTTPS or SSH address.")
        }
        let destination = Project.standardize(cloneParent).appending(path: remote.folderName)
        let shown = (destination.path as NSString).abbreviatingWithTildeInPath

        // Checked and reserved with no await in between, so two clones to one folder
        // cannot both get past here.
        if clones.values.contains(where: { $0.summary.folder == destination }) {
            throw JSONRPCError(code: DaemonAPI.Failure.folderInTheWay,
                               message: "\(shown) is already being cloned.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            return try await adopt(destination, cloneOf: remote, shown: shown)
        }

        let id = UUID()
        let summary = DaemonAPI.CloneSummary(id: id, url: remote.url, folder: destination, startedAt: now())
        clones[id] = RunningClone(summary: summary)
        broadcast(DaemonAPI.Notification.cloneChanged, DaemonAPI.CloneNotification(clone: summary, finished: false))

        let holder = cloneStaging.appending(path: id.uuidString, directoryHint: .isDirectory)
        let staged = holder.appending(path: remote.folderName, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: holder)
            clones[id] = nil
            broadcast(DaemonAPI.Notification.cloneChanged, DaemonAPI.CloneNotification(clone: summary, finished: true))
        }

        let outcome: GitProcess.Outcome
        do {
            try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: true)
            let url = cloneURLRewrite?(remote.url) ?? remote.url
            // `--` so nothing in the URL is ever read as an option.
            let git = try GitProcess(["clone", "--", url, staged.path])
            clones[id]?.process = git
            outcome = try await git.run()
        } catch GitProcess.LaunchError.notInstalled {
            throw JSONRPCError(code: DaemonAPI.Failure.cloneFailed, message: CloneFailure.notInstalled)
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.cloneFailed,
                               message: "Could not start git: \(error.localizedDescription)")
        }
        guard outcome.succeeded else {
            DaemonLog.shared.write("clone of \(remote.url) failed (\(outcome.status)): \(outcome.errors)")
            throw JSONRPCError(code: DaemonAPI.Failure.cloneFailed,
                               message: CloneFailure.explain(outcome.errors, remote: remote))
        }

        do {
            // Refuses rather than replaces if something arrived there while git ran.
            try FileManager.default.moveItem(at: staged, to: destination)
        } catch {
            if FileManager.default.fileExists(atPath: destination.path) {
                throw JSONRPCError(code: DaemonAPI.Failure.folderInTheWay,
                                   message: "\(shown) appeared while the clone ran. Nothing in it was changed.")
            }
            throw JSONRPCError(code: DaemonAPI.Failure.cloneFailed,
                               message: "Cloned, but could not move it to \(shown): \(error.localizedDescription)")
        }
        return try await addProject(destination)
    }

    /// The folder is already there. If it is a checkout of this repository it is the
    /// project, exactly as it is; anything else is refused and left alone.
    private func adopt(_ folder: URL, cloneOf remote: GitRemote, shown: String) async throws -> DaemonAPI.ProjectSummary {
        let remotes = Self.isDirectory(folder) ? await GitProcess.remoteURLs(of: folder) : []
        guard remotes.contains(where: { GitRemote($0)?.identity == remote.identity }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.folderInTheWay,
                               message: "\(shown) is already there and is not a clone of \(remote.host)/\(remote.path). Nothing in it was changed.")
        }
        let standardized = Project.standardize(folder)
        if projectRecords()[standardized]?.isArchived == true {
            return try await unarchiveProject(standardized)
        }
        return try await addProject(standardized)
    }
}
