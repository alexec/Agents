import Foundation

/// Workflows: the prompts a project keeps that run themselves.
///
/// All of it lives in the daemon rather than the app, for the reason the daemon exists
/// at all — it "keeps going when there is no window", and a workflow belongs to its
/// project rather than to whatever happens to be on screen.
///
/// The three seams this hangs off were already here. `move(_:on:)` is the one funnel
/// every agent state change passes through, so it is the whole of the lifecycle trigger
/// surface. `FolderWatch` already turns FSEvents into coalesced directory changes.
/// `start` and `prompt` already know how to begin a conversation and pick one back up,
/// so nothing here opens a session itself.
extension DaemonCore {
    // MARK: Starting up

    /// Read every project's workflows, watch their folders, and start the clock.
    public func startWorkflows() async {
        for project in allProjects(includeArchived: false) where project.exists {
            adoptWorkflows(in: project.folder)
        }
        startWorkflowTicker()
    }

    /// Take a project's workflows on: read them once, and watch for more.
    ///
    /// Idempotent and cheap to call often, which it has to be — the hot path into here
    /// is every agent that changes state. A project already being watched costs one
    /// dictionary lookup and nothing else; only a project arriving for the first time
    /// pays for a directory read.
    ///
    /// Called from everywhere a project can become live: added by hand, unarchived, or
    /// simply the first agent to run in a folder nobody had named before. Doing it only
    /// at startup was wrong in exactly the case that matters most — a project added
    /// this session, which is where somebody trying the feature will write their first
    /// workflow.
    func adoptWorkflows(in folder: URL) {
        let standardized = Project.standardize(folder)
        guard workflowWatchers[standardized] == nil else { return }
        guard Self.isDirectory(standardized) else { return }
        loadWorkflows(in: standardized)
        watchWorkflows(in: standardized)
        let held = workflows[standardized]?.values ?? [:].values
        guard !held.isEmpty else { return }
        // Read once for the lot rather than once each: this is a file read, and a
        // project may hold a few dozen workflows.
        let records = workflowStore.load()
        for workflow in held {
            broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow, records: records))
        }
    }


    /// One watcher per project, rooted at the project rather than at its workflow
    /// folder.
    ///
    /// Watching the leaf would be cheaper per event and wrong at the only boundary that
    /// matters: FSEvents on a path that does not exist reports nothing, so the first
    /// workflow anybody ever adds to a project — the exact moment this has to work —
    /// would go unnoticed. Watching the root and filtering costs a string comparison on
    /// paths we were handed anyway.
    func watchWorkflows(in folder: URL) {
        let standardized = Project.standardize(folder)
        guard workflowWatchers[standardized] == nil, Self.isDirectory(standardized) else { return }
        workflowWatchers[standardized] = FolderWatch(root: standardized) { [weak self] changed in
            guard changed.contains(where: { $0.path.contains("/.agents") }) else { return }
            Task { await self?.scheduleWorkflowRescan(in: standardized) }
        }
    }

    /// Stop watching everything. Called as the daemon goes.
    func stopWatchingAllWorkflows() {
        for (_, watch) in workflowWatchers { watch.stop() }
        workflowWatchers.removeAll()
    }

    /// Let a project's workflows go: an archived project's do not fire.
    ///
    /// The cached workflows go with the watcher, so nothing is left scheduled against a
    /// project somebody has put away. The files are untouched — unarchiving reads them
    /// straight back.
    func forgetWorkflows(in folder: URL) {
        let standardized = Project.standardize(folder)
        stopWatchingWorkflows(in: standardized)
        let letGo = workflows.removeValue(forKey: standardized) ?? [:]
        for id in letGo.keys {
            broadcast(DaemonAPI.Notification.workflowRemoved,
                      DaemonAPI.WorkflowRemovedNotification(folder: standardized, workflowID: id))
        }
    }

    func stopWatchingWorkflows(in folder: URL) {
        let standardized = Project.standardize(folder)
        // Stopped, not merely let go. `FolderWatch` hands itself to FSEvents with
        // `passRetained`, so the only thing that releases it is `stop()` — dropping the
        // reference leaks the stream, and enough of those exhaust the process. This is
        // the same call `FilesPane` makes in `onDisappear`, and for the same reason.
        workflowWatchers.removeValue(forKey: standardized)?.stop()
        workflowRescans.removeValue(forKey: standardized)?.cancel()
    }

    /// A rescan, shortly. FSEvents has already collapsed a burst; this collapses what
    /// is left, so a build that touches `.agents` forty times re-reads one small
    /// directory once.
    func scheduleWorkflowRescan(in folder: URL) {
        workflowRescans[folder]?.cancel()
        workflowRescans[folder] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.rescanWorkflows(in: folder)
        }
    }

    /// Re-read one project's workflow folder and tell the windows what moved.
    public func rescanWorkflows(in folder: URL) {
        let standardized = Project.standardize(folder)
        workflowRescans.removeValue(forKey: standardized)
        let before = workflows[standardized] ?? [:]
        loadWorkflows(in: standardized)
        let after = workflows[standardized] ?? [:]

        for (id, workflow) in after where before[id] != workflow {
            broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow))
        }
        for id in before.keys where after[id] == nil {
            broadcast(DaemonAPI.Notification.workflowRemoved,
                      DaemonAPI.WorkflowRemovedNotification(folder: standardized, workflowID: id))
        }
    }

    func loadWorkflows(in folder: URL) {
        let standardized = Project.standardize(folder)
        let found = WorkflowFolder.workflows(in: standardized)
        workflows[standardized] = Dictionary(uniqueKeysWithValues: found.map { ($0.workflowID, $0) })
    }

    // MARK: Reading

    public func allWorkflows(in folder: URL? = nil) -> [WorkflowSummary] {
        // Asking is what adopts a project this daemon has not seen before.
        //
        // Driven by somebody looking rather than by agents moving: a window opening a
        // project page asks for exactly this, which is the moment watching starts to
        // matter, and it costs one dictionary lookup for a project already held. The
        // first version adopted on every agent state change instead, which put a
        // directory read, a file read and an FSEvents stream on the path of starting an
        // agent — slow enough that the daemon's own tests began missing deadlines.
        if let folder { adoptWorkflows(in: folder) }
        let folders = folder.map { [Project.standardize($0)] } ?? Array(workflows.keys)
        // Read once for the whole answer rather than once per workflow: this is the
        // call a window makes when it opens, and a project may hold a few dozen.
        let records = workflowStore.load()
        return folders
            .flatMap { workflows[$0]?.values ?? [:].values }
            .map { summary(for: $0, records: records) }
            .sorted { $0.workflow.name.localizedCaseInsensitiveCompare($1.workflow.name) == .orderedAscending }
    }

    /// One workflow, adopting its project first if this daemon has not seen it.
    ///
    /// Adoption is what reads a project's workflow folder, and every caller of this is
    /// somebody asking about a workflow by name — which means the project is one they
    /// are already looking at. Without this, pausing or running a workflow before
    /// anything had listed it answered "there is no such workflow", which is true only
    /// in the sense that nobody had looked yet.
    func workflow(_ workflowID: String, in folder: URL) -> Workflow? {
        let standardized = Project.standardize(folder)
        if workflows[standardized] == nil { adoptWorkflows(in: standardized) }
        return workflows[standardized]?[workflowID]
    }

    /// A workflow plus everything the app knows about it, resolved here so that two
    /// windows cannot disagree about when it next runs.
    func summary(for workflow: Workflow, records: WorkflowRecords? = nil) -> WorkflowSummary {
        let records = records ?? workflowStore.load()
        let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)
        let paused = state?.isPaused ?? false || records.isPaused(folder: workflow.folder)
        return WorkflowSummary(
            workflow: workflow,
            isPaused: paused,
            nextFireAt: paused ? nil : workflow.nextDue(after: Date()),
            lastOutcome: state?.lastOutcome,
            isRunning: workflowRuns[workflow.id] != nil)
    }

    // MARK: The clock

    /// How often the scheduler looks. Not how often a workflow runs.
    ///
    /// Short and repeating rather than one sleep until the next due time, because a
    /// sleep-until-due is a bet on whether the clock advances across a lid close, and
    /// it is wrong the moment the machine changes time zone or the clocks go back.
    /// Reading `Date()` every fifteen seconds needs no such bet, and fifteen against a
    /// one-minute promise leaves room for a tick that lands during a busy moment.
    static let workflowTickInterval = Duration.seconds(15)

    /// How long a silence has to be before it counts as the daemon having been away,
    /// rather than a tick that ran late.
    static let workflowMissedThreshold: TimeInterval = 120

    func startWorkflowTicker() {
        workflowTicker?.cancel()
        workflowTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: DaemonCore.workflowTickInterval)
                guard !Task.isCancelled else { return }
                await self?.tickWorkflows(now: Date())
            }
        }
    }

    /// One pass of the clock. `now` is a parameter so a test can drive a week through
    /// this in a millisecond rather than waiting for one.
    public func tickWorkflows(now: Date) async {
        var records = workflowStore.load()
        let since = records.lastTickAt
        records.lastTickAt = now
        workflowStore.save(records)

        // The first tick after starting has no window to look at. Everything before the
        // daemon existed is somebody else's business.
        guard let since, since < now else { return }
        // A gap longer than a couple of ticks is the machine having been asleep or the
        // app closed. Anything due inside it was missed, and is said so rather than
        // fired: opening the app after a weekend must not start a queue of agents
        // nobody asked for.
        let wasAway = now.timeIntervalSince(since) > Self.workflowMissedThreshold

        for (folder, byID) in workflows {
            for workflow in byID.values {
                guard let due = workflow.nextDue(after: since), due <= now else { continue }
                if wasAway {
                    record(.refused(.missedWhileClosed, at: now, repeats: 1), for: workflow)
                } else {
                    await fire(workflow, on: .schedule(WorkflowSchedule()), at: now)
                }
                _ = folder
            }
        }
    }

    // MARK: Firing

    /// Ask a workflow to run, and either run it or say why not.
    ///
    /// Every path out of here leaves a mark. That is the whole of the third user story:
    /// a fire that produces no agent and no record is indistinguishable from a trigger
    /// that never matched, and the first thing anybody does then is edit the file that
    /// was never the problem.
    @discardableResult
    func fire(_ workflow: Workflow, on trigger: WorkflowTrigger,
              triggeringAgentID: UUID? = nil, depth: Int = 0,
              at now: Date = Date()) async -> WorkflowRefusal? {
        let records = workflowStore.load()
        let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)

        var triggeringAgentIsUsable: Bool?
        if workflow.mode == .triggering, let triggeringAgentID {
            triggeringAgentIsUsable = agents[triggeringAgentID]?.state != .archived
                && agents[triggeringAgentID] != nil
        }

        if let refusal = workflow.refusalIfBlocked(
            isPaused: state?.isPaused ?? false,
            projectIsPaused: records.isPaused(folder: workflow.folder),
            isRunning: workflowRuns[workflow.id] != nil,
            depth: depth,
            folderExists: Self.isDirectory(workflow.folder),
            triggeringAgentIsUsable: triggeringAgentIsUsable) {
            record(.refused(refusal, at: now, repeats: 1), for: workflow)
            return refusal
        }

        var run = WorkflowRun(workflowID: workflow.workflowID, folder: workflow.folder,
                              trigger: trigger, triggeringAgentID: triggeringAgentID,
                              depth: depth, startedAt: now)
        // Claimed before anything is awaited: starting a runtime is a long await, and
        // without this a second trigger arriving inside it sees no run in flight and
        // starts a second agent. The check above and this line have no await between
        // them, which on an actor is the whole of the lock.
        workflowRuns[workflow.id] = run
        broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow, records: records))

        do {
            let agentID = try await runAgent(for: workflow, run: run)
            run.agentID = agentID
            workflowRuns[workflow.id] = run
            record(.ran(agentID: agentID, at: now), for: workflow)
            return nil
        } catch {
            workflowRuns.removeValue(forKey: workflow.id)
            let message = (error as? JSONRPCError)?.message ?? error.localizedDescription
            record(.refused(.unreadable(message), at: now, repeats: 1), for: workflow)
            return .unreadable(message)
        }
    }

    /// Which agent gets the prompt, and getting it to them.
    private func runAgent(for workflow: Workflow, run: WorkflowRun) async throws -> UUID {
        let prompt = promptText(for: workflow, run: run)

        switch workflow.mode {
        case .triggering:
            guard let agentID = run.triggeringAgentID else {
                throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                                   message: "Nothing triggered it, so there was no agent to resume.")
            }
            try await adoptAndPrompt(agentID: agentID, prompt: prompt, workflow: workflow, run: run)
            return agentID

        case .standing:
            var records = workflowStore.load()
            let standing = records.state(folder: workflow.folder,
                                         workflowID: workflow.workflowID)?.standingAgentID
            // A standing agent that is still here is picked back up. One that has gone
            // is replaced, and the replacement adopted, so a workflow whose agent was
            // archived last week is not dead — it simply starts again.
            if let standing, agents[standing] != nil, agents[standing]?.state != .archived {
                try await adoptAndPrompt(agentID: standing, prompt: prompt, workflow: workflow, run: run)
                return standing
            }
            let agentID = try await startAgent(for: workflow, run: run, prompt: prompt)
            records = workflowStore.load()
            records.update(folder: workflow.folder, workflowID: workflow.workflowID) {
                $0.standingAgentID = agentID
            }
            workflowStore.save(records)
            return agentID

        case .new:
            return try await startAgent(for: workflow, run: run, prompt: prompt)
        }
    }

    private func startAgent(for workflow: Workflow, run: WorkflowRun, prompt: String) async throws -> UUID {
        let request = DaemonAPI.StartRequest(
            runtimeID: RuntimeCatalog.builtIn[0].id,
            cwd: workflow.folder,
            prompt: prompt)
        let agentID = try await start(request)
        if var agent = agents[agentID] {
            agent.startedByWorkflow = workflow.workflowID
            agent.startedByRun = run.id
            agent.title = workflow.name
            changed(agent)
        }
        return agentID
    }

    private func adoptAndPrompt(agentID: UUID, prompt: String,
                                workflow: Workflow, run: WorkflowRun) async throws {
        if var agent = agents[agentID] {
            agent.startedByWorkflow = workflow.workflowID
            agent.startedByRun = run.id
            changed(agent)
        }
        try await self.prompt(DaemonAPI.PromptRequest(agentID: agentID, text: prompt))
    }

    /// The body, plus what caused it.
    ///
    /// The prompt is the file's, verbatim — no templating and no substitution, because
    /// a placeholder syntax is a language nobody asked to learn. What a lifecycle
    /// trigger adds is a sentence saying what happened, so an agent starting fresh has
    /// something to act on rather than being told to review a thing it cannot name.
    private func promptText(for workflow: Workflow, run: WorkflowRun) -> String {
        guard let agentID = run.triggeringAgentID, let agent = agents[agentID] else {
            return workflow.prompt
        }
        let name = agent.title ?? "an untitled agent"
        let what: String
        switch run.trigger {
        case .agentFinished: what = "has just finished its work"
        case .agentAskedPermission: what = "is waiting for permission"
        case .agentAskedForm: what = "is waiting on a form"
        case .agentStopped: what = "stopped without finishing"
        default: what = "triggered this"
        }
        return """
            \(workflow.prompt)

            (You were started by the workflow "\(workflow.name)" because \(name) \(what).)
            """
    }

    /// Write down what a fire produced, then tell the windows. That order is why a
    /// daemon killed mid-fire still leaves something true behind.
    func record(_ outcome: WorkflowOutcome, for workflow: Workflow) {
        var records = workflowStore.load()
        records.record(outcome, folder: workflow.folder, workflowID: workflow.workflowID)
        workflowStore.save(records)
        broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow, records: records))
    }

    // MARK: What an agent doing something sets off

    /// How deep a fire caused by this agent would be.
    ///
    /// One deeper than the run that produced the agent; zero for an agent nobody
    /// automated. Read *before* the run is released, because releasing it is what makes
    /// a finished agent's depth unfindable — and a depth that silently resets to zero is
    /// a loop the limit never stops.
    func workflowChainDepth(causedBy agentID: UUID) -> Int {
        guard let runID = agents[agentID]?.startedByRun,
              let run = workflowRuns.values.first(where: { $0.id == runID }) else { return 0 }
        return run.depth + 1
    }

    /// Called from the one funnel every agent state change goes through.
    func workflowsRespond(to event: WorkflowAgentEvent, agentID: UUID, depth: Int? = nil) {
        guard let agent = agents[agentID] else { return }
        let folder = Project.standardize(agent.cwd)
        guard let byID = workflows[folder], !byID.isEmpty else { return }
        let depth = depth ?? workflowChainDepth(causedBy: agentID)

        let trigger: WorkflowTrigger
        switch event {
        case .finished: trigger = .agentFinished
        case .askedPermission: trigger = .agentAskedPermission
        case .askedForm: trigger = .agentAskedForm
        case .stopped: trigger = .agentStopped
        }

        for workflow in byID.values where workflow.responds(to: event) {
            // Detached, because this is called from inside the actor by `move`, and
            // firing awaits things that can call back into it. The shape `beginTurn`
            // already uses for a turn.
            Task { [weak self] in
                await self?.fire(workflow, on: trigger,
                                 triggeringAgentID: agentID, depth: depth)
            }
        }
    }

    /// A run is over. Release the workflow, and let anything chained off it go.
    func workflowRunFinished(agentID: UUID) {
        guard let agent = agents[agentID], let runID = agent.startedByRun,
              let (key, run) = workflowRuns.first(where: { $0.value.id == runID }) else { return }
        workflowRuns.removeValue(forKey: key)
        if let workflow = workflow(run.workflowID, in: run.folder) {
            broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow))
        }

        let folder = Project.standardize(run.folder)
        guard let byID = workflows[folder] else { return }
        for other in byID.values where other.respondsToCompletion(of: run.workflowID) {
            Task { [weak self] in
                await self?.fire(other, on: .workflowCompleted(id: run.workflowID),
                                 depth: run.depth + 1)
            }
        }
    }

    // MARK: What the app asks for

    /// Run now.
    ///
    /// Not a bypass. It ignores the schedule and starts a chain at zero, and it still
    /// obeys the in-flight and paused rules — returning the refusal on the summary
    /// rather than swallowing it. Somebody is watching when they tap this, so being
    /// told why is more important here than anywhere else.
    public func runWorkflow(_ request: DaemonAPI.WorkflowRequest) async throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        await fire(workflow, on: .schedule(WorkflowSchedule()))
        return summary(for: workflow)
    }

    public func pauseWorkflow(_ request: DaemonAPI.WorkflowPauseRequest) throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        var records = workflowStore.load()
        records.update(folder: request.folder, workflowID: request.workflowID) {
            $0.isPaused = request.paused
        }
        workflowStore.save(records)
        let summary = summary(for: workflow, records: records)
        broadcast(DaemonAPI.Notification.workflowChanged, summary)
        return summary
    }

    public func pauseProjectWorkflows(_ request: DaemonAPI.WorkflowPauseProjectRequest) -> [WorkflowSummary] {
        var records = workflowStore.load()
        records.setPaused(request.paused, folder: request.folder)
        workflowStore.save(records)
        let summaries = (workflows[Project.standardize(request.folder)]?.values ?? [:].values)
            .map { summary(for: $0, records: records) }
        for summary in summaries {
            broadcast(DaemonAPI.Notification.workflowChanged, summary)
        }
        return summaries
    }
}
