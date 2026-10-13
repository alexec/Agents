import Foundation
import AgentsKitCore

/// How much each worktree holds on disk, and freeing its build output (#790).
///
/// On 2026-10-03 the disk filled with 80 GB of worktrees, and nothing said which. A list
/// never waits for a walk: `worktrees/list` gives each worktree's size as last measured,
/// asks for the ones not measured in the last ten minutes, and they are walked one at a
/// time off the actor, each within `worktreeMeasureBudget`; `worktrees/sized` then tells
/// every client, so a list already drawn fills in.
extension DaemonCore {
    /// How long a size is given again before the worktree is walked again.
    static let worktreeSizeLifetime: TimeInterval = 600

    /// Put the worktrees not measured lately in line to be, and start measuring if
    /// nothing is. One already in line or being walked is not added twice.
    func wantSizes(of roots: [URL]) {
        let at = now()
        // Bounded by the worktrees listed: one gone a while drops out here.
        worktreeSizes = worktreeSizes.filter { at.timeIntervalSince($0.value.at) < 2 * Self.worktreeSizeLifetime }
        for root in roots {
            if let held = worktreeSizes[root.path], at.timeIntervalSince(held.at) < Self.worktreeSizeLifetime { continue }
            guard !worktreeSizeQueue.contains(root) else { continue }
            worktreeSizeQueue.append(root)
        }
        guard worktreeSizeTask == nil, !worktreeSizeQueue.isEmpty else { return }
        worktreeSizeTask = Task { [weak self] in await self?.measureWaitingWorktrees() }
    }

    /// A test's own budget, to see a walk run out.
    func setWorktreeMeasureBudget(files: Int, time: Duration) {
        worktreeMeasureBudget = (files, time)
    }

    /// Walk each worktree in line, one at a time, and say what each holds.
    private func measureWaitingWorktrees() async {
        while !worktreeSizeQueue.isEmpty, !Task.isCancelled {
            let root = worktreeSizeQueue.removeFirst()
            let budget = worktreeMeasureBudget
            let measured: DiskWorktree? = await Task.detached {
                guard FileManager.default.fileExists(atPath: root.path) else { return nil }
                return Self.measure(root, files: budget.files, until: ContinuousClock.now.advanced(by: budget.time))
            }.value
            guard let measured else { continue }
            let size = DaemonAPI.WorktreeSize(bytes: measured.bytes, partial: measured.partial)
            worktreeSizes[root.path] = (size, now())
            broadcast(DaemonAPI.Notification.worktreesSized,
                      DaemonAPI.WorktreesSized(sizes: [DaemonAPI.WorktreeSizeNote(root: root, size: size)]))
        }
        worktreeSizeTask = nil
    }

    /// `worktrees/all`: every project's worktrees, the project folders left out, for
    /// Activity ▸ Worktrees. A worktree two projects share (folders of one repository)
    /// is listed once, under the first.
    public func allWorktrees() async -> [DaemonAPI.ProjectWorktrees] {
        var seen = Set<String>()
        var found: [DaemonAPI.ProjectWorktrees] = []
        for project in allProjects(includeArchived: false) where project.exists {
            let listed = await listWorktrees(for: project.folder)
            let worktrees = listed.worktrees.filter { !$0.isProjectFolder && seen.insert($0.root.path).inserted }
            if !worktrees.isEmpty {
                found.append(DaemonAPI.ProjectWorktrees(project: Project.standardize(project.folder), worktrees: worktrees))
            }
        }
        return found
    }

    /// `worktrees/removeBuildOutput`: delete the build output in a worktree the app made
    /// and nobody works in — `build`, `.build`, `DerivedData`, `node_modules`, `target`
    /// and `dist`, at the top and one folder down — but only what git ignores and
    /// tracks nothing in: a `dist` that is checked in is somebody's work.
    public func removeBuildOutput(_ request: DaemonAPI.WorktreeRemovalRequest) async throws -> DaemonAPI.BuildOutputRemoved {
        let facts = try await removalFacts(request)
        let name = facts.root.lastPathComponent
        guard facts.madeByApp else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                               message: "\(name) was not made by this app, so it is not this app's to clean.")
        }
        guard facts.check.blockedBy.isEmpty else {
            let names = facts.check.blockedBy.compactMap { agents[$0]?.title ?? "an agent" }
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeInUse,
                               message: "Still in use by \(names.joined(separator: ", ")). Archive them first.")
        }
        guard facts.exists else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeMissing,
                               message: "The worktree \(name) is not there any more.")
        }
        let root = facts.root
        let candidates = Self.buildOutputCandidates(in: root)
        let ignored = await Self.ignoredByGit(candidates, in: root)
        let budget = worktreeMeasureBudget
        let (removed, freed) = await Task.detached { () -> ([String], DaemonAPI.WorktreeSize) in
            let deadline = ContinuousClock.now.advanced(by: budget.time)
            var removed: [String] = []
            var freed = DaemonAPI.WorktreeSize(bytes: 0)
            for relative in ignored {
                let folder = root.appending(path: relative, directoryHint: .isDirectory)
                let held = Self.measure(folder, files: budget.files, until: deadline)
                guard (try? FileManager.default.removeItem(at: folder)) != nil else { continue }
                removed.append(relative)
                freed.bytes += held.bytes
                freed.partial = freed.partial || held.partial
            }
            return (removed, freed)
        }.value
        worktreeSizes[root.path] = nil
        wantSizes(of: [root])
        return DaemonAPI.BuildOutputRemoved(removed: removed, freed: freed)
    }

    /// The build output folders in a worktree, relative to it: real folders, not links.
    nonisolated static func buildOutputCandidates(in root: URL) -> [String] {
        func isFolder(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        var found = buildOutputNames.filter { children.contains($0) && isFolder(root.appending(path: $0)) }
        for child in children where !child.hasPrefix(".") && !buildOutputNames.contains(child)
            && isFolder(root.appending(path: child)) {
            for name in buildOutputNames where isFolder(root.appending(path: "\(child)/\(name)")) {
                found.append("\(child)/\(name)")
            }
        }
        return found
    }

    /// Those of `paths` git ignores in `root`. None when git cannot say.
    static func ignoredByGit(_ paths: [String], in root: URL) async -> [String] {
        guard !paths.isEmpty else { return [] }
        // check-ignore exits 1 when it ignores none of them, which is a failure to `git`.
        guard let output = try? await GitWorktrees.git(["check-ignore", "--"] + paths, in: root) else { return [] }
        let ignored = Set(output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) })
        var found: [String] = []
        // An ignored folder holding a file added anyway is somebody's work too.
        for path in paths where ignored.contains(path) {
            guard let tracked = try? await GitWorktrees.git(["ls-files", "--", path], in: root), tracked.isEmpty
            else { continue }
            found.append(path)
        }
        return found
    }
}
