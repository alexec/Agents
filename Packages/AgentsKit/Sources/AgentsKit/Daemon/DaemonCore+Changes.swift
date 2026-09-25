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
        let fold = try await reported(for: agent.id)
        return ChangesList(files: Self.reportedFiles(fold, for: agent),
                           git: .unavailable(.notARepository),
                           reportsEdits: fold.reportsEdits)
    }

    public func changesFile(_ request: DaemonAPI.ChangesFileRequest) async throws -> ChangedFileDetail {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        let fold = try await reported(for: agent.id)
        let path = ReportedChanges.key(request.path)
        guard let file = Self.reportedFiles(fold, for: agent).first(where: { $0.path == path }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notChanged,
                               message: "\(URL(filePath: path).lastPathComponent) has not changed.")
        }
        let edits = fold.byFile.first { $0.path == path }?.edits ?? []
        return ChangedFileDetail(file: file, edits: edits)
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
