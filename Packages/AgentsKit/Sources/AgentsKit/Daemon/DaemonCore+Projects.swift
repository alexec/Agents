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
/// Every project's folder and its name among the others, as `projectIndex` keeps them
/// (#204), with what they were made from.
struct ProjectIndex {
    var folders: Set<URL>
    var names: [URL: String]
    /// `AgentTable.foldersVersion` and `TombstoneTable.foldersVersion` when made.
    var agentFolders: Int
    var tombstoneFolders: Int
}

extension DaemonCore {
    // MARK: Reading

    /// Every project, named, stamped and counted, from each folder's tally (#164), each
    /// for the cost of one lookup in the kept index (#204).
    public func allProjects(includeArchived: Bool = true) -> [DaemonAPI.ProjectSummary] {
        let records = projectRecords()
        let index = projectIndex()
        var summaries = index.folders.compactMap { summary(of: $0, records: records, index: index) }
        if !includeArchived { summaries = summaries.filter { !$0.project.isArchived } }
        return summaries.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The union: every folder an agent is in, and every folder we kept a record for.
    /// And every folder a retired agent was in, so a project whose agents have all
    /// been retired keeps what it cost (051).
    func projectFolders() -> Set<URL> {
        projectIndex().folders
    }

    /// Whether a folder is a project: a lookup, for a caller that needs nothing more.
    func isProject(_ folder: URL) -> Bool {
        projectIndex().folders.contains(Project.standardize(folder))
    }

    /// The folders and their names, made again only when the set of folders has moved
    /// (#204): a folder gaining its first agent or losing its last, a record kept or
    /// changed, a tombstone in a folder that had none. Until then every project-wide call
    /// reads it as it is, rather than each project's summary making it again.
    func projectIndex() -> ProjectIndex {
        loadRetentionIfNeeded()
        let records = projectRecords()
        if let projectIndexCache, projectIndexCache.agentFolders == agents.foldersVersion,
           projectIndexCache.tombstoneFolders == retired.foldersVersion {
            return projectIndexCache
        }
        projectIndexBuilds += 1
        var folders = Set(agents.tallies.keys)
        folders.formUnion(records.keys)
        folders.formUnion(retired.tallies.keys)
        let names: [URL: String]
        if let projectIndexCache, projectIndexCache.folders == folders {
            names = projectIndexCache.names
        } else {
            names = ProjectNaming.displayNames(for: Array(folders))
        }
        let index = ProjectIndex(folders: folders, names: names, agentFolders: agents.foldersVersion,
                                 tombstoneFolders: retired.foldersVersion)
        projectIndexCache = index
        return index
    }

    /// One project's summary from its tally, its record and its tombstones: the same
    /// thing `rebuiltProjects` says of it, for the cost of one project rather than every
    /// agent there has ever been (#164), and without looking at any other project (#204).
    /// Nil when the folder is not a project.
    func summary(of folder: URL, records: [URL: Project], index: ProjectIndex,
                 freshExistence: Bool = false) -> DaemonAPI.ProjectSummary? {
        let tally = agents.tallies[folder]
        let gone = retired.tallies[folder]
        guard tally != nil || records[folder] != nil || gone != nil else { return nil }
        var project = records[folder]
            ?? Project(folder: folder, addedAt: tally?.oldestCreated ?? gone?.oldestCreated ?? Date())
        var costToDate = tally?.costToDate ?? [:]
        for (currency, amount) in gone?.costToDate ?? [:] {
            costToDate[currency, default: 0] += amount
        }
        let newest = tally?.newestActivity ?? gone?.newestActivity ?? project.addedAt
        project.helperLimits = configuredHelperLimits(in: project.folder)
        project.diskSpace = configuredDiskSpace(in: project.folder)
        var summary = DaemonAPI.ProjectSummary(
            project: project,
            name: index.names[folder] ?? folder.lastPathComponent,
            exists: folderExists(folder, fresh: freshExistence),
            lastActivityAt: newest,
            counts: tally?.counts ?? [:],
            costToDate: costToDate,
            unmeasuredAgents: tally?.unmeasured ?? 0)
        summary.retiredCount = gone?.count ?? 0
        return summary
    }

    /// Every project's name, disambiguated against the others.
    func projectNames() -> [URL: String] {
        projectIndex().names
    }

    /// How long a watched project folder's existence is believed without its watch
    /// saying anything: a folder moved away whole is not heard by a watch rooted inside it.
    static let folderExistenceFresh: TimeInterval = 30

    /// Whether a project's folder is there (#204). A folder under a project watch is
    /// looked at once and believed until the watch hears anything in it; any other, and
    /// any single project's summary (`fresh`), is looked at each time, which is one stat.
    func folderExists(_ folder: URL, fresh: Bool = false) -> Bool {
        let at = now()
        if !fresh, let seen = folderExistence[folder], at >= seen.at,
           at.timeIntervalSince(seen.at) < Self.folderExistenceFresh {
            return seen.exists
        }
        let exists = Self.isDirectory(folder)
        if projectWatches[folder] != nil { folderExistence[folder] = (exists, at) }
        else { folderExistence[folder] = nil }
        return exists
    }

    /// Every project, counted the long way from every agent held: what the tallies are
    /// checked against (`ProjectTallyTests`). Not called by the daemon itself.
    func rebuiltProjects(includeArchived: Bool = true) -> [DaemonAPI.ProjectSummary] {
        let records = projectRecords()
        let agentsByFolder = Dictionary(grouping: agents.values) { $0.projectFolder }
        let retiredByFolder = Dictionary(grouping: retired.values) { Project.standardize($0.project) }

        // The union: every folder an agent is in, and every folder we kept a record for.
        // And every folder a retired agent was in, so a project whose agents have all
        // been retired keeps what it cost (051).
        var folders = Set(agentsByFolder.keys)
        folders.formUnion(records.keys)
        folders.formUnion(retiredByFolder.keys)

        var projects: [Project] = folders.map { folder in
            if let kept = records[folder] { return kept }
            // Derived. A project nobody archived and nobody added by hand is as old as
            // its oldest agent, so the sidebar's order means something on day one.
            let oldest = agentsByFolder[folder]?.map(\.createdAt).min()
                ?? retiredByFolder[folder]?.map(\.createdAt).min() ?? Date()
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
            // A retired agent still cost what it cost: retiring changes no total (051).
            let gone = retiredByFolder[project.folder] ?? []
            for tombstone in gone {
                for (currency, amount) in tombstone.costToDate {
                    costToDate[currency, default: 0] += amount
                }
            }
            let newest = inFolder.map(\.lastActivityAt).max()
                ?? gone.map(\.lastActivityAt).max() ?? project.addedAt
            // The limits are the project's own file's (#126), not the record's.
            var project = project
            project.helperLimits = configuredHelperLimits(in: project.folder)
            project.diskSpace = configuredDiskSpace(in: project.folder)
            var summary = DaemonAPI.ProjectSummary(
                project: project,
                name: names[project.folder] ?? project.folder.lastPathComponent,
                exists: Self.isDirectory(project.folder),
                lastActivityAt: newest,
                counts: counts,
                costToDate: costToDate,
                unmeasuredAgents: unmeasured)
            summary.retiredCount = gone.count
            return summary
        }
        .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// One project, or nil when that folder is not one.
    func projectSummary(for folder: URL) -> DaemonAPI.ProjectSummary? {
        summary(of: Project.standardize(folder), records: projectRecords(), index: projectIndex(),
                freshExistence: true)
    }

    /// The kept records, by folder.
    func projectRecords() -> [URL: Project] {
        if let projectRecordsCache { return projectRecordsCache }
        var byFolder: [URL: Project] = [:]
        for project in projectStore.load() { byFolder[project.folder] = project }
        projectRecordsCache = byFolder
        return byFolder
    }

    /// Written first and held after, so a change the disk refused does not look kept
    /// until the next restart (#88). The refusal is in words for the call that asked.
    func saveProjectRecords(_ records: [URL: Project]) throws {
        try keep("the project list") { try projectStore.save(Array(records.values)) }
        projectRecordsCache = records
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
    ///
    /// Only when it says something new (#164): a label or a plan moves the agent and
    /// nothing in its project's row. While retirements are being noted they are held,
    /// and each project is told once at the end.
    func projectChanged(forAgentIn folder: URL) {
        let folder = Project.standardize(folder)
        if heldProjectChanges != nil {
            heldProjectChanges?.insert(folder)
            return
        }
        guard let summary = projectSummary(for: folder) else { return }
        guard lastProjectSent[folder] != summary else { return }
        sendProject(summary)
    }

    /// Every `project/changed` goes through here, so `lastProjectSent` is what the
    /// windows were last told.
    func sendProject(_ summary: DaemonAPI.ProjectSummary) {
        lastProjectSent[summary.folder] = summary
        broadcast(DaemonAPI.Notification.projectChanged, summary)
    }

    // MARK: Writing

    /// Add a folder as a project before anything has run in it, laid out the dotagents
    /// way (`DotAgents`).
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
            try saveProjectRecords(records)
        }
        layOutOnce(standardized)
        guard let summary = projectSummary(for: standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) could not be added.")
        }
        adoptWorkflows(in: standardized)
        sendProject(summary)
        // A project's needs go with it when it is archived and come back when it is not;
        // nothing else about a project moves a need.
        reconsider()
        return summary
    }

    /// Give a project the dotagents layout, unless it has had it already.
    ///
    /// Called when a project is added and whenever a runtime session is made in a
    /// folder, so a project that was there before this existed is laid out the first
    /// time an agent starts in it — before the runtime has read anything. A folder in
    /// one of the app's own worktrees is left alone: it is a checkout of the project,
    /// and whatever the project has committed is already in it.
    func layOutOnce(_ folder: URL) {
        let standardized = Project.standardize(folder)
        guard !standardized.path.contains("/\(WorktreeName.folder)/"),
              Self.isDirectory(standardized) else { return }
        var records = projectRecords()
        // A folder that became a project by an agent running in it has no record yet;
        // the one made here keeps the age the derived project already had.
        let oldest = agents.tallies[standardized]?.oldestCreated
        var record = records[standardized] ?? Project(folder: standardized, addedAt: oldest ?? Date())
        // Once for each step: a project laid out by an older layout gets only what
        // was added since, never the steps it already had back.
        let from = record.laidOutAt == nil ? 0 : record.layoutVersion ?? 1
        guard from < DotAgents.version else { return }
        DotAgents.apply(to: standardized, from: from)
        record.laidOutAt = record.laidOutAt ?? Date()
        record.layoutVersion = DotAgents.version
        records[standardized] = record
        // Nobody waits on this: a session is starting. Told, and tried again next time.
        do {
            try projectStore.save(Array(records.values))
            projectRecordsCache = records
        } catch {
            lost(error, keeping: "the project list")
        }
    }

    /// The `_meta` a session in `cwd` is made with: the runtime's tool scoping, and the
    /// project's plugins for a runtime that takes them that way. Worked out on every
    /// session, so a plugin added to `.agents/plugins` is there from the next one — and
    /// so is its line in the project's marketplace index, for the runtimes that load
    /// plugins only from one.
    ///
    /// Only the plugins the person has approved (security review, S2): one waiting is in
    /// neither the `_meta` nor the index until they do.
    /// `managesAgents` is false for an agent another agent started. Grok's rules name
    /// only the tools that session's server will offer, so a helper is not told how to
    /// call `start_agent`.
    func sessionMeta(runtimeID: String, cwd: URL, managesAgents: Bool = true,
                     sandbox: SandboxChoice = .runtime) -> JSONValue? {
        Self.merging(scopingMeta(runtimeID: runtimeID, cwd: cwd, managesAgents: managesAgents),
                     LaunchSandbox.meta(runtimeID: runtimeID, choice: sandbox))
    }

    private func scopingMeta(runtimeID: String, cwd: URL, managesAgents: Bool) -> JSONValue? {
        let plugins = approvedPluginFolders(for: cwd)
        DotAgents.refreshPlugins(for: cwd, approved: plugins)
        // The person's own plugins after the project's (054, R12), for the runtimes that
        // take plugins this way.
        let personal = locations.personalHome.map(PersonalDotAgents.personalPluginFolders) ?? []
        let policy = ToolPolicyCatalog.policy(for: runtimeID)
        let meta = Self.merging(policy.sessionMeta,
                                DotAgents.sessionMeta(runtimeID: runtimeID, plugins: plugins + personal))
        guard policy.appToolSchemaDelivery == .sessionRules else { return meta }
        return Self.merging(meta, ["rules": .string(AppToolPreface.rules(managesAgents: managesAgents))])
    }

    /// Two `_meta` objects as one, key by key and all the way down, because Claude's
    /// scoping and its plugins both live in `claudeCode.options`.
    static func merging(_ base: JSONValue?, _ added: JSONValue?) -> JSONValue? {
        guard let base else { return added }
        guard let added else { return base }
        guard case .object(var merged) = base, case .object(let more) = added else { return added }
        for (key, value) in more { merged[key] = merging(merged[key], value) }
        return .object(merged)
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
        let live = agents.agents(in: standardized)
            .filter { $0.state.holdsRuntime }
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
        try saveProjectRecords(records)

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
        sendProject(summary)
        // A project's needs go with it when it is archived and come back when it is not;
        // nothing else about a project moves a need.
        reconsider()
        return summary
    }

    /// The person setting a project's two helper limits (#64), from any window or paired
    /// client (#111): `ConnectionRole` keeps it from agents.
    ///
    /// Written to the project's own `.agents/project.json` (#126), so the limits go
    /// wherever the project goes; nothing about them is kept in `projects.json` any more.
    /// Refused outside the hard maximums rather than clamped, so the person reads what
    /// was kept rather than finding out later. Lowering a limit below what is in use
    /// stops nothing: it refuses the next start until enough have finished or been
    /// archived.
    public func setHelperLimits(_ request: DaemonAPI.SetHelperLimitsRequest) throws -> DaemonAPI.ProjectSummary {
        let standardized = Project.standardize(request.folder)
        guard projectSummary(for: standardized) != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not a project.")
        }
        if let problem = request.limits.problem {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: problem)
        }
        guard Self.isDirectory(standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not there, so its settings cannot be written.")
        }
        try writeHelperLimits(request.limits, in: standardized)
        // A record from before #126 says nothing now: the file does.
        var records = projectRecords()
        if records[standardized]?.helperLimits != nil {
            records[standardized]?.helperLimits = nil
            try saveProjectRecords(records)
        }
        guard let summary = projectSummary(for: standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not a project.")
        }
        sendProject(summary)
        // A raised limit may make room for what is queued (#362).
        checkQueueSoon(in: standardized)
        return summary
    }

    /// Write the limits into the project's file, in the person's words when it can't be.
    private func writeHelperLimits(_ limits: HelperLimits?, in folder: URL) throws {
        do {
            try ProjectConfig.setHelperLimits(limits, in: folder)
        } catch let unreadable as ProjectConfig.Unreadable {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: unreadable.message)
        } catch {
            let name = "\(DotAgents.folder)/\(ProjectConfig.fileName)"
            if let failure = WriteFailure(error, keeping: name) { throw Self.refusal(failure) }
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: "\(name) could not be written: \(error.localizedDescription)")
        }
        projectConfigCache[folder] = nil
    }

    /// What the project's file sets, read once until it changes; before a project's
    /// limits have been moved into its file, what `projects.json` kept.
    func configuredHelperLimits(in folder: URL) -> HelperLimits? {
        let standardized = Project.standardize(folder)
        let fromFile: HelperLimits?
        if let known = projectConfigCache[standardized] {
            fromFile = known
        } else {
            fromFile = ProjectConfig.helperLimits(in: standardized)
            projectConfigCache[standardized] = .some(fromFile)
        }
        return fromFile ?? projectRecords()[standardized]?.helperLimits
    }

    /// The helper limits enforced in a project: the person's, or the defaults, never
    /// past the hard maximums whatever the file says.
    func helperLimits(in folder: URL) -> (running: Int, notArchived: Int) {
        (configuredHelperLimits(in: folder) ?? HelperLimits()).effective
    }

    /// Whether agents may archive the helpers they started in a project (#120): the
    /// person's choice, or the default.
    func agentsMayArchive(in folder: URL) -> Bool {
        (configuredHelperLimits(in: folder) ?? HelperLimits()).mayArchive
    }

    /// The project's `.agents` changed on disk, by hand or by a pull: its limits are
    /// read again, and the windows told if they moved.
    func projectConfigFilesChanged(_ changed: [URL], in folder: URL) {
        let file = ProjectConfig.url(in: folder).path
        guard changed.contains(where: { $0.path == file || file.hasPrefix($0.path + "/") || $0.path == file + "/" })
        else { return }
        let before = projectConfigCache[folder] ?? nil
        let diskBefore = diskSpaceConfigCache[folder] ?? nil
        projectConfigCache[folder] = nil
        diskSpaceConfigCache[folder] = nil
        let diskMoved = configuredDiskSpace(in: folder) != diskBefore
        if diskMoved { scheduleDiskCheck() }
        guard configuredHelperLimits(in: folder) != before || diskMoved,
              let summary = projectSummary(for: folder) else { return }
        sendProject(summary)
    }

    /// Helper limits kept in `projects.json` before #126, written into each project's
    /// own file once and then forgotten there. A folder that is not here keeps its
    /// record, which still counts, for a later start; a file that already sets limits
    /// wins over the record.
    func migrateHelperLimitsToProjectFiles() {
        var records = projectRecords()
        var changed = false
        for (folder, record) in records {
            guard let limits = record.helperLimits, Self.isDirectory(folder) else { continue }
            do {
                if ProjectConfig.helperLimits(in: folder) == nil {
                    try ProjectConfig.setHelperLimits(limits, in: folder)
                    DaemonLog.shared.write("wrote \(folder.lastPathComponent)'s helper limits into its project file")
                }
                records[folder]?.helperLimits = nil
                projectConfigCache[folder] = nil
                changed = true
            } catch {
                DaemonLog.shared.write("could not write \(folder.lastPathComponent)'s helper limits into its project file yet: \(error)")
            }
        }
        guard changed else { return }
        keepQuietly("the project list") { try saveProjectRecords(records) }
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
        try saveProjectRecords(records)
        adoptWorkflows(in: standardized)

        guard let summary = projectSummary(for: standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not a project.")
        }
        sendProject(summary)
        // A project's needs go with it when it is archived and come back when it is not;
        // nothing else about a project moves a need.
        reconsider()
        return summary
    }
}
