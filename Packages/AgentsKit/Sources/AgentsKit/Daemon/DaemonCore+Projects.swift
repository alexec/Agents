import Foundation

/// Projects: the folders the work happens in.
///
/// Almost nothing about a project is stored. The list is the union of every folder an
/// agent has run in and every record we kept, and a record is only kept when there is
/// something to remember — that it is archived, or that somebody added the folder
/// before anything ran in it.
///
/// That union is what makes agents written before this feature appear under projects
/// with nothing to migrate: their folder is already on their record. It is also what
/// makes an agent arriving by a route nobody thought about — an adopted session, a
/// fork — land in the right project without being told.
extension DaemonCore {
    // MARK: Reading

    /// Every project, named, stamped and counted.
    public func allProjects(includeArchived: Bool = true) -> [DaemonAPI.ProjectSummary] {
        let records = projectRecords()
        let agentsByFolder = Dictionary(grouping: agents.values) { Project.standardize($0.cwd) }

        // The union: every folder an agent is in, and every folder we kept a record for.
        var folders = Set(agentsByFolder.keys)
        folders.formUnion(records.keys)

        var projects: [Project] = folders.map { folder in
            if let kept = records[folder] { return kept }
            // Derived. A project nobody archived and nobody added by hand is as old as
            // its oldest agent, so the sidebar's order means something on day one.
            let oldest = agentsByFolder[folder]?.map(\.createdAt).min() ?? Date()
            return Project(folder: folder, addedAt: oldest)
        }
        if !includeArchived { projects = projects.filter { !$0.isArchived } }

        let names = ProjectNaming.displayNames(for: projects.map(\.folder))
        return projects.map { project in
            let inFolder = agentsByFolder[project.folder] ?? []
            var counts: [AgentGroup: Int] = [:]
            // What the folder has cost, over the whole life of everything in it.
            // Nothing filters by state, group or archived flag: the daemon holds every
            // agent there has ever been, and counting all of them is exactly what makes
            // archiving one change no total. Per currency, because adding two of them
            // would be a number nobody could check.
            var costToDate: [String: Decimal] = [:]
            var unmeasured = 0
            for agent in inFolder {
                // Without eyes, and said so. The daemon has no window and stores
                // nothing about a file being looked at — it refuses to show one when no
                // window is open — so it cannot know whether an agent is waiting to be
                // looked at. This is the count a surface that cannot show a file takes
                // as complete (the phone); the Mac window completes it from its own
                // grouping, `AgentsModel.counts(in:)`, which has the fact (FR-009).
                counts[agent.group(wantsEyes: false), default: 0] += 1
                for (currency, amount) in agent.costToDate {
                    costToDate[currency, default: 0] += amount
                }
                if agent.isUnmeasured { unmeasured += 1 }
            }
            let newest = inFolder.map(\.lastActivityAt).max() ?? project.addedAt
            return DaemonAPI.ProjectSummary(
                project: project,
                name: names[project.folder] ?? project.folder.lastPathComponent,
                exists: Self.isDirectory(project.folder),
                lastActivityAt: newest,
                counts: counts,
                costToDate: costToDate,
                unmeasuredAgents: unmeasured)
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// One project, or nil when that folder is not one.
    func projectSummary(for folder: URL) -> DaemonAPI.ProjectSummary? {
        let standardized = Project.standardize(folder)
        return allProjects().first { $0.folder == standardized }
    }

    /// The kept records, by folder.
    func projectRecords() -> [URL: Project] {
        if let projectRecordsCache { return projectRecordsCache }
        var byFolder: [URL: Project] = [:]
        for project in projectStore.load() { byFolder[project.folder] = project }
        projectRecordsCache = byFolder
        return byFolder
    }

    func saveProjectRecords(_ records: [URL: Project]) {
        projectRecordsCache = records
        try? projectStore.save(Array(records.values))
    }

    static func isDirectory(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        return there && isDirectory.boolValue
    }

    /// Tell the windows a project moved.
    ///
    /// Sent after the agent change that caused it, because an agent changing state is
    /// what moves a project's counts, and a sidebar that says a project needs you is
    /// this notification arriving in a window that is looking somewhere else.
    func projectChanged(forAgentIn folder: URL) {
        guard let summary = projectSummary(for: folder) else { return }
        broadcast(DaemonAPI.Notification.projectChanged, summary)
    }

    // MARK: Writing

    /// Add a folder as a project before anything has run in it.
    ///
    /// Idempotent: adding a folder that is already a project returns it unchanged, so
    /// two windows racing settle on the same thing rather than one of them failing.
    public func addProject(_ folder: URL) async throws -> DaemonAPI.ProjectSummary {
        let standardized = Project.standardize(folder)
        guard Self.isDirectory(standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.folderGone,
                               message: "\(standardized.path) is not there any more.")
        }
        var records = projectRecords()
        if records[standardized] == nil {
            records[standardized] = Project(folder: standardized)
            saveProjectRecords(records)
        }
        guard let summary = projectSummary(for: standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) could not be added.")
        }
        adoptWorkflows(in: standardized)
        broadcast(DaemonAPI.Notification.projectChanged, summary)
        // A project's needs go with it when it is archived and come back when it is not;
        // nothing else about a project moves a need.
        reconsider()
        return summary
    }

    /// Put a project away.
    ///
    /// Refused while anything in it is live, and the refusal names them. This is
    /// deliberately unlike archiving an agent, which stops the one it was given:
    /// stopping one agent somebody just pointed at is small and visible, and silently
    /// cancelling four turns because they tidied the sidebar is not.
    public func archiveProject(_ folder: URL) async throws -> DaemonAPI.ProjectSummary {
        let standardized = Project.standardize(folder)
        guard projectSummary(for: standardized) != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not a project.")
        }
        let live = agents.values
            .filter { Project.standardize($0.cwd) == standardized && $0.state.holdsRuntime }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
        if !live.isEmpty {
            let names = live.map { $0.title ?? "an agent" }
            throw JSONRPCError(code: DaemonAPI.Failure.projectHasLiveAgents,
                               message: "Stop these first: \(names.joined(separator: ", ")).")
        }

        var records = projectRecords()
        var record = records[standardized] ?? Project(folder: standardized)
        record.archivedAt = Date()
        records[standardized] = record
        saveProjectRecords(records)

        // Its workflows stop being watched and stop being scheduled. Their files are
        // untouched — putting a project away is not editing it — and unarchiving reads
        // them straight back.
        forgetWorkflows(in: standardized)

        // The agents are left exactly as they are. Their own states and archived flags
        // are what unarchiving restores, so nothing here touches them.
        guard let summary = projectSummary(for: standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not a project.")
        }
        broadcast(DaemonAPI.Notification.projectChanged, summary)
        // A project's needs go with it when it is archived and come back when it is not;
        // nothing else about a project moves a need.
        reconsider()
        return summary
    }

    /// Bring one back. Succeeds whether or not the folder is still there: the agents
    /// and their transcripts are the point, and `exists` says the rest.
    public func unarchiveProject(_ folder: URL) async throws -> DaemonAPI.ProjectSummary {
        let standardized = Project.standardize(folder)
        var records = projectRecords()
        guard var record = records[standardized], record.isArchived else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not an archived project.")
        }
        record.archivedAt = nil
        records[standardized] = record
        saveProjectRecords(records)
        adoptWorkflows(in: standardized)

        guard let summary = projectSummary(for: standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not a project.")
        }
        broadcast(DaemonAPI.Notification.projectChanged, summary)
        // A project's needs go with it when it is archived and come back when it is not;
        // nothing else about a project moves a need.
        reconsider()
        return summary
    }
}
