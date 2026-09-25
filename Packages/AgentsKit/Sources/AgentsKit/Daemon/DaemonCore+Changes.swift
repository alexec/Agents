import Foundation

/// What an agent changed (035): the Changes pane's two questions.
///
/// Answered here rather than in a window because a window holds one page of the
/// transcript, and a list of changes that stops at the page is a list that is wrong
/// without saying so.
extension DaemonCore {
    /// The agent's reported edits, brought up to the end of its transcript.
    ///
    /// Caught up from the store on every ask rather than fed as entries are written:
    /// the first ask for a long-lived agent reads its whole transcript across an
    /// `await`, and entries written in that gap would otherwise be missed, or folded
    /// twice. Catching up by count has no gap to fall into.
    func reported(for agentID: UUID) async throws -> ReportedChanges {
        while true {
            let held = reportedChanges[agentID] ?? HeldChanges()
            let count = try await store.transcriptCount(for: agentID)
            if count <= held.through { return held.fold }
            let page = try await store.transcript(for: agentID, before: count,
                                                  limit: count - held.through)
            // Another ask caught up while this one was reading. Start again from
            // whatever it left rather than folding the same entries twice.
            guard (reportedChanges[agentID]?.through ?? 0) == held.through else { continue }
            var fold = held.fold
            for (offset, entry) in page.entries.enumerated() {
                fold.absorb(entry, at: page.firstIndex + offset)
            }
            reportedChanges[agentID] = HeldChanges(fold: fold, through: count)
            return fold
        }
    }

    /// Where an agent's changes are measured from: the commit its folder is on now,
    /// taken once, as it starts. Saved without telling the windows; nothing they show
    /// reads it.
    func takeStartingPoint(for agentID: UUID, in folder: URL) async {
        guard agents[agentID]?.startingPoint == nil,
              let point = await GitChanges.startingPoint(of: folder),
              var agent = agents[agentID], agent.startingPoint == nil else { return }
        agent.startingPoint = point
        agents[agentID] = agent
        saveQuietly(agent)
    }

    public func changesList(_ request: DaemonAPI.ChangesListRequest) async throws -> ChangesList {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        return try await changes(of: agent).list
    }

    public func changesFile(_ request: DaemonAPI.ChangesFileRequest) async throws -> ChangedFileDetail {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        let (list, fold, git) = try await changes(of: agent)
        let path = ReportedChanges.key(request.path)
        guard let file = list.files.first(where: { $0.path == path }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "\(URL(filePath: path).lastPathComponent) has not changed.")
        }
        let edits = fold.byFile.first { $0.path == path }?.edits ?? []
        var detail = ChangedFileDetail(file: file, edits: edits)
        if request.whole, let git, !file.outsideFolder, file.state != .binary,
           let relative = Self.relative(path, to: git.rootPath) {
            if file.state == .added, let text = Self.currentText(of: path) {
                // New since the agent started, whether git tracks it yet or not: all of
                // it came in.
                detail.whole = GitChanges.allLines(of: text, as: .added)
            } else {
                detail.whole = try? await GitChanges.whole(of: relative, since: git.since, in: git.root)
            }
        }
        return detail
    }

    /// Where git is asked, and from what.
    struct GitContext: Sendable {
        var root: URL
        var rootPath: String
        var since: String
        /// The agent's folder, relative to the top, when it is not the top.
        var scope: String?
    }

    /// The list, the fold it came from, and git's context when there is one.
    func changes(of agent: Agent) async throws -> (list: ChangesList, fold: ReportedChanges, git: GitContext?) {
        let fold = try await reported(for: agent.id)
        var files = Self.reportedFiles(fold, for: agent)
        let (context, view) = await gitContext(for: agent)
        guard let context else {
            return (ChangesList(files: files, git: view, reportsEdits: fold.reportsEdits), fold, nil)
        }
        do {
            let changed = try await GitChanges.changed(since: context.since, in: context.root,
                                                       scope: context.scope)
            files = Self.merge(changed, into: files, git: context, for: agent)
            try await Self.markBeyondReported(&files, fold: fold, git: context)
            return (ChangesList(files: files, git: view, reportsEdits: fold.reportsEdits), fold, context)
        } catch GitChanges.Failure.notInstalled {
            return (ChangesList(files: files, git: .unavailable(.gitNotInstalled),
                                reportsEdits: fold.reportsEdits), fold, nil)
        } catch GitChanges.Failure.refused(let message) {
            return (ChangesList(files: files, git: .unavailable(.failed(message: message)),
                                reportsEdits: fold.reportsEdits), fold, nil)
        }
    }

    /// What git's view is measured from, and whose it can be said to be (R3, R6).
    func gitContext(for agent: Agent) async -> (GitContext?, GitView) {
        guard GitProcess.executable() != nil else { return (nil, .unavailable(.gitNotInstalled)) }
        guard Self.isDirectory(agent.cwd) else { return (nil, .unavailable(.folderGone)) }
        let root: URL
        let since: String
        let view: GitView
        if let point = agent.startingPoint, Self.isDirectory(point.repository) {
            root = point.repository
            since = point.commit
            view = ownsItsFolder(agent) ? .owned(since: since) : .shared(since: since)
        } else if let found = try? await GitChanges.repositoryRoot(of: agent.cwd) {
            // Started before 035, or somewhere git could not answer then: what is
            // uncommitted is the most that can be said.
            root = found
            since = "HEAD"
            view = .sharedFromHead
        } else {
            return (nil, .unavailable(.notARepository))
        }
        let rootPath = root.resolvingSymlinksInPath().path
        let scope = Self.relative(agent.cwd.resolvingSymlinksInPath().path, to: rootPath)
        return (GitContext(root: root, rootPath: rootPath, since: since,
                           scope: scope?.isEmpty == true ? nil : scope), view)
    }

    /// An agent's own worktree, and nobody else's: what git sees there is its work
    /// (FR-009). Anything else — the project folder, a worktree two agents chose — is
    /// shared, and git's view there is never presented as this agent's (FR-008).
    func ownsItsFolder(_ agent: Agent) -> Bool {
        guard let worktree = agent.worktree else { return false }
        let root = worktree.root.resolvingSymlinksInPath().path
        return !agents.values.contains { other in
            other.id != agent.id && other.state != .archived
                && (other.cwd.resolvingSymlinksInPath().path == root
                    || Self.relative(other.cwd.resolvingSymlinksInPath().path, to: root) != nil)
        }
    }

    /// Git's files folded into the reported ones: a file both know is one row, marked
    /// as both; a file only git knows follows the reported ones, by path.
    static func merge(_ changed: [GitChanges.Changed], into reported: [ChangedFile],
                      git: GitContext, for agent: Agent) -> [ChangedFile] {
        var files = reported
        var index = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.path, $0) })
        let base = (agent.startingPoint?.repository ?? agent.cwd).resolvingSymlinksInPath().path
        var seen: [ChangedFile] = []
        for change in changed {
            let path = git.rootPath + "/" + change.path
            var added = change.added
            var removed = change.removed
            var binary = change.added == nil && change.status != "?" && change.status != "D"
            if change.status == "?" {
                // Untracked: git counts nothing, so the lines are read here.
                if let counted = untrackedCount(path) { added = counted; removed = 0 } else { binary = true }
            }
            let state: ChangeState = binary ? .binary
                : change.status == "D" ? .deleted
                : (change.status == "A" || change.status == "?") ? .added : .modified
            if let at = index[path] {
                files[at].source = .reportedAndSeen
                files[at].state = state
                files[at].added = binary ? nil : added
                files[at].removed = binary ? nil : removed
            } else {
                seen.append(ChangedFile(path: path, relativePath: relative(path, to: base) ?? change.path,
                                        source: .seen, state: state,
                                        added: binary ? nil : added, removed: binary ? nil : removed))
                index[path] = -1
            }
        }
        return files + seen.sorted { $0.path < $1.path }
    }

    /// Lines in an untracked file, or nil when it is binary or too big to read.
    static func untrackedCount(_ path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path),
              data.count <= firstLineReadLimit,
              !data.prefix(8_000).contains(0) else { return nil }
        return ReportedEdit.lineCount(String(decoding: data, as: UTF8.self))
    }

    /// For every file both the runtime and git know about: do its reported edits,
    /// played over its text where the agent started, make what is on disk (R5)?
    static func markBeyondReported(_ files: inout [ChangedFile], fold: ReportedChanges,
                                   git: GitContext) async throws {
        let edits = Dictionary(fold.byFile.map { ($0.path, $0.edits) }, uniquingKeysWith: { a, _ in a })
        let checked = files.indices.filter {
            files[$0].source == .reportedAndSeen && files[$0].state != .binary
                && files[$0].state != .deleted
        }
        let relatives = checked.compactMap { relative(files[$0].path, to: git.rootPath) }
        let starts = try await GitChanges.texts(of: relatives, at: git.since, in: git.root)
        for at in checked {
            let path = files[at].path
            guard let relative = relative(path, to: git.rootPath),
                  let now = currentText(of: path), let made = edits[path] else { continue }
            files[at].beyondReported = !EditReplay.accounts(for: made, start: starts[relative] ?? "",
                                                            now: now)
        }
    }

    /// One row per file the runtime reported, in the order of each file's first edit,
    /// then any file only a call still running has touched.
    static func reportedFiles(_ fold: ReportedChanges, for agent: Agent) -> [ChangedFile] {
        let running = fold.inProgress
        let base = (agent.startingPoint?.repository ?? agent.cwd).resolvingSymlinksInPath().path
        var files = fold.byFile.map { path, edits in
            let current = Self.currentText(of: path)
            var file = ChangedFile(
                path: path,
                relativePath: relative(path, to: base),
                source: .reported,
                state: current == nil ? .deleted : (edits.first?.oldText == nil ? .added : .modified),
                editCount: edits.count,
                added: edits.reduce(0) { $0 + $1.addedLines },
                removed: edits.reduce(0) { $0 + $1.removedLines },
                inProgress: running.contains(path),
                outsideFolder: relative(path, to: base) == nil)
            file.firstLine = current.flatMap { firstLine(of: edits, in: $0) }
            return file
        }
        let listed = Set(files.map(\.path))
        for path in running.subtracting(listed).sorted() {
            files.append(ChangedFile(path: path, relativePath: relative(path, to: base),
                                     source: .reported,
                                     state: FileManager.default.fileExists(atPath: path) ? .modified : .added,
                                     inProgress: true,
                                     outsideFolder: relative(path, to: base) == nil))
        }
        return files
    }

    /// Nil when the path is not inside the folder.
    static func relative(_ path: String, to base: String) -> String? {
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Files bigger than this are not read to find where their changes start.
    static let firstLineReadLimit = 2_000_000

    /// The file as it is now; nil when it is not there.
    static func currentText(of path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        if let size = attributes[.size] as? Int, size > firstLineReadLimit { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Where "Open in Files" puts the reader: the line holding the first thing the
    /// earliest edit that is still in the file put there.
    static func firstLine(of edits: [ReportedEdit], in text: String) -> Int? {
        if edits.first?.oldText == nil, edits.count == 1 { return 1 }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for edit in edits {
            guard let wanted = edit.newText.split(separator: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
            if let index = lines.firstIndex(where: { $0 == wanted }) { return index + 1 }
        }
        return nil
    }
}

/// An agent's reported edits as the daemon holds them: the fold, and how many
/// transcript entries it has taken in.
struct HeldChanges: Sendable {
    var fold = ReportedChanges()
    var through = 0
}
