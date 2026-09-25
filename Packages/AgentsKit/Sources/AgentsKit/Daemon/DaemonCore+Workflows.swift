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
        // After adoption, because a run is judged against the workflow files, and before
        // the held events are replayed, so nothing they fire collides with a run that is
        // already over.
        pruneWorkflowRuns()
        startWorkflowTicker()
        workflowsAreStarted = true
        // Whatever happened while this layer could not act, now, and in the order it
        // happened — which for a restart is `recover`'s order, most recently active
        // first. Taken out of the array before any of it is replayed, so an event that
        // somehow defers again lands on an empty queue instead of a growing one.
        let waiting = deferredLifecycleEvents
        deferredLifecycleEvents.removeAll()
        for held in waiting {
            workflowsRespond(to: held.event, agentID: held.agentID, depth: held.depth, causingEvent: held.cause)
        }
        // And the events whose new-style triggers could not be matched yet (042).
        let events = deferredEventsForWorkflows
        deferredEventsForWorkflows.removeAll()
        for event in events { fireWorkflows(for: event) }
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
        let archived = state?.isArchived ?? false
        let overLimit = archived ? nil : limitReached(by: workflow, records: records)
        return WorkflowSummary(
            workflow: workflow,
            isArchived: archived,
            overLimit: overLimit,
            nextFireAt: archived || overLimit != nil ? nil : workflow.nextDue(after: Date()),
            lastOutcome: state?.lastOutcome,
            isRunning: isRunning(workflow),
            causingEvent: state?.lastCausingEvent,
            causingEventName: state?.lastCausingEvent.flatMap { eventLog.event(at: $0) }.map(Self.eventLabel))
    }

    /// Whether any run of it is in flight: its own, or one for any of its pull requests
    /// (038 R9), whose keys are its id with `#<number>` after it.
    func isRunning(_ workflow: Workflow) -> Bool {
        workflowRuns.keys.contains { $0 == workflow.id || $0.hasPrefix(workflow.id + "#") }
    }

    /// What the in-flight table holds a run under.
    func runKey(for workflow: Workflow, pullRequest: Int?) -> String {
        pullRequest.map { "\(workflow.id)#\($0)" } ?? workflow.id
    }

    /// Every workflow this daemon will act on, in the order the ceilings are applied:
    /// each project's first few by file name, then the first few of those overall.
    ///
    /// By name rather than by age, and by project path rather than by when a project
    /// was added, because a folder has no reliable age — a checkout writes every file
    /// at the same instant — and because two machines looking at the same work have to
    /// come out with the same list.
    ///
    /// Archived workflows are not in it at all. That is the whole reason archiving is
    /// the way to make room: it is the one move that changes this list without
    /// deleting anybody's file.
    func liveWorkflowIDs(records: WorkflowRecords) -> [(folder: URL, workflowID: String)] {
        let perProject = workflows.keys.sorted { $0.path < $1.path }.flatMap { folder in
            (workflows[folder] ?? [:]).keys
                .filter { records.state(folder: folder, workflowID: $0)?.isArchived != true }
                .sorted()
                .prefix(WorkflowLimit.project.allowed)
                .map { (folder: folder, workflowID: $0) }
        }
        return Array(perProject.prefix(WorkflowLimit.total.allowed))
    }

    /// The ones from a single project, which is what the tool counts before writing.
    func liveWorkflowIDs(in folder: URL, records: WorkflowRecords) -> [String] {
        let standardized = Project.standardize(folder)
        return liveWorkflowIDs(records: records)
            .filter { $0.folder == standardized }
            .map(\.workflowID)
    }

    /// How many of a project's workflows are live — not archived — which is what the
    /// per-project ceiling counts.
    func liveWorkflowCount(in folder: URL, records: WorkflowRecords) -> Int {
        let standardized = Project.standardize(folder)
        return (workflows[standardized] ?? [:]).keys
            .filter { records.state(folder: standardized, workflowID: $0)?.isArchived != true }
            .count
    }

    /// How many are live everywhere, which is what the total ceiling counts. Each
    /// project contributes at most its own allowance: ten projects holding three each
    /// is thirty, and the point of the total is that it is not.
    func liveWorkflowCount(records: WorkflowRecords) -> Int {
        workflows.keys.reduce(0) { running, folder in
            running + min(liveWorkflowCount(in: folder, records: records),
                          WorkflowLimit.project.allowed)
        }
    }

    /// Which ceiling, if either, this workflow is past. Archived ones are past neither:
    /// they are out of the way, which is the point of archiving.
    func limitReached(by workflow: Workflow, records: WorkflowRecords) -> WorkflowLimit? {
        guard records.state(folder: workflow.folder,
                            workflowID: workflow.workflowID)?.isArchived != true else { return nil }
        // Its own project first. Told that this project is full, somebody knows where to
        // look; told the machine is full when it is their fourth here, they do not.
        let mine = (workflows[workflow.folder] ?? [:]).keys
            .filter { records.state(folder: workflow.folder, workflowID: $0)?.isArchived != true }
            .sorted()
            .prefix(WorkflowLimit.project.allowed)
        guard mine.contains(workflow.workflowID) else { return .project }
        let live = liveWorkflowIDs(records: records)
        let isLive = live.contains { $0.folder == workflow.folder && $0.workflowID == workflow.workflowID }
        return isLive ? nil : .total
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
        // The power source, noticed on the heartbeat that is already running rather
        // than on a timer of its own — the same trick the day rollover below uses, and
        // the reason 024 needs no clock of its own (024 FR-011).
        //
        // `readingPower: true` is the whole point of the call: every other caller
        // reaches `reviseWakefulness` because an *agent* moved and is allowed to skip
        // the IOKit read, so this is the only thing that ever notices a laptop being
        // unplugged, or its charge crossing the floor, under a turn that is still
        // running.
        //
        // **Above the `guard let since` below, deliberately.** That guard returns on the
        // first tick after starting and whenever the clock has not moved, and neither
        // has anything to do with the battery. Put this after it and a Mac unplugged in
        // the first fifteen seconds is held awake until the tick after that.
        //
        // It is only ever a backstop for agent-side causes: a turn ending releases the
        // hold from `changed(_:)`, in the same call that records the ending. Nothing
        // here waits fifteen seconds for that (024 T033).
        reviseWakefulness(readingPower: true)

        // Blocked agents whose time to check again has come (039). Here, above the
        // guard below, for the same reason as the battery: the first tick after a start
        // is exactly when a Mac that slept through the time should catch up.
        await resumeDueBlocks(now: now)

        // Pull requests that are due a look (038 R3), also above the guard: the first
        // tick after a start is when a restarted daemon should catch up. It starts a
        // sweep and returns; the sweep runs beside the clock, not on it.
        sweepPullRequestsIfDue(now: now)

        // The day rolling over, noticed on the heartbeat that is already running
        // rather than on a timer of its own. `now` is the parameter this already
        // takes, so midnight is testable without waiting for it.
        //
        // What was holding becomes promptable again where it stands, with its
        // conversation intact — a held agent is an ordinary settled agent with an
        // undrained queue, so draining is the whole of it.
        let today = SpendLedger.stamp(for: now)
        if lastSeenDay != today {
            let rolled = lastSeenDay != nil
            lastSeenDay = today
            if rolled {
                broadcastCostState()
                await drainEverythingHolding()
            }
        }

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
                // Nothing is recorded against an archived one, here or on a lifecycle
                // event. A refusal is news, and "the thing you put away did not run"
                // is not news every half hour for as long as the file exists.
                guard records.state(folder: folder, workflowID: workflow.workflowID)?
                    .isArchived != true else { continue }
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
              at now: Date = Date(), pullRequest: PullRequestFire? = nil,
              causingEvent: EventPosition? = nil) async -> WorkflowRefusal? {
        let key = runKey(for: workflow, pullRequest: pullRequest?.pull.number)
        var triggeringAgentID = triggeringAgentID
        if let pullRequest {
            // Its own checks first, in R9's order: somewhere to work, babysitting not
            // stopped, nothing uncommitted, nobody else working there.
            if let refusal = await pullRequestRefusal(for: workflow, pullRequest) {
                record(.refused(refusal, at: now, repeats: 1), for: workflow, causingEvent: causingEvent, depth: depth)
                notePullRequestOutcome(.refused(refusal, at: now, repeats: 1), workflow: workflow, pullRequest)
                return refusal
            }
            // `triggering` resumes the agent last active in its worktree (FR-017).
            if workflow.mode == .triggering, let worktree = pullRequest.pull.worktree {
                triggeringAgentID = agents(in: worktree, folder: pullRequest.folder)
                    .max { $0.lastActivityAt < $1.lastActivityAt }?.id
            }
        }
        let records = workflowStore.load()
        let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)

        var triggeringAgentIsUsable: Bool?
        if workflow.mode == .triggering, let triggeringAgentID {
            triggeringAgentIsUsable = agents[triggeringAgentID]?.state != .archived
                && agents[triggeringAgentID] != nil
        }

        if let refusal = workflow.refusalIfBlocked(
            isRunning: workflowRuns[key] != nil,
            depth: depth,
            isArchived: state?.isArchived ?? false,
            overLimit: limitReached(by: workflow, records: records),
            dayLimitReached: isDayLimitReached(),
            folderExists: Self.isDirectory(workflow.folder),
            triggeringAgentIsUsable: triggeringAgentIsUsable) {
            record(.refused(refusal, at: now, repeats: 1), for: workflow, causingEvent: causingEvent, depth: depth)
            if let pullRequest {
                notePullRequestOutcome(.refused(refusal, at: now, repeats: 1), workflow: workflow, pullRequest)
            }
            return refusal
        }

        var run = WorkflowRun(workflowID: workflow.workflowID, folder: workflow.folder,
                              trigger: trigger, triggeringAgentID: triggeringAgentID,
                              depth: depth, startedAt: now, pullRequest: pullRequest?.ref)
        // Claimed before anything is awaited: starting a runtime is a long await, and
        // without this a second trigger arriving inside it sees no run in flight and
        // starts a second agent. The check above and this line have no await between
        // them, which on an actor is the whole of the lock.
        workflowRuns[key] = run
        // Written the moment it is claimed, not once its agent exists: a daemon that goes
        // while the runtime is still starting leaves a run the next one can find its
        // agent for, by `startedByRun`, rather than one it never knew was in flight.
        persistWorkflowRuns()
        broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow, records: records))

        do {
            let agentID = try await runAgent(for: workflow, run: run, pullRequest: pullRequest)
            run.agentID = agentID
            workflowRuns[key] = run
            persistWorkflowRuns()
            record(.ran(agentID: agentID, at: now), for: workflow, causingEvent: causingEvent, depth: depth)
            if let pullRequest {
                notePullRequestRan(agentID: agentID, at: now, workflow: workflow, pullRequest)
            }
            return nil
        } catch let refused as SettingRefused {
            // Its own refusal, and not `.unreadable`: the file is perfectly readable,
            // and telling somebody their workflow cannot be read when what is wrong is
            // one word in it sends them looking in the wrong place. This one also
            // collapses on the setting, so a weekend of the same refusal is one row.
            workflowRuns.removeValue(forKey: key)
            persistWorkflowRuns()
            let refusal = WorkflowRefusal.settingRefused(setting: refused.setting,
                                                         detail: refused.detail)
            record(.refused(refusal, at: now, repeats: 1), for: workflow, causingEvent: causingEvent, depth: depth)
            if let pullRequest {
                notePullRequestOutcome(.refused(refusal, at: now, repeats: 1), workflow: workflow, pullRequest)
            }
            return refusal
        } catch {
            workflowRuns.removeValue(forKey: key)
            persistWorkflowRuns()
            let message = (error as? JSONRPCError)?.message ?? error.localizedDescription
            record(.refused(.unreadable(message), at: now, repeats: 1), for: workflow, causingEvent: causingEvent, depth: depth)
            if let pullRequest {
                notePullRequestOutcome(.refused(.unreadable(message), at: now, repeats: 1),
                                       workflow: workflow, pullRequest)
            }
            return .unreadable(message)
        }
    }

    /// Which agent gets the prompt, and getting it to them.
    private func runAgent(for workflow: Workflow, run: WorkflowRun,
                          pullRequest: PullRequestFire? = nil) async throws -> UUID {
        var prompt = promptText(for: workflow, run: run)
        if let pullRequest { prompt += await pullRequestPromptBlock(for: workflow, pullRequest) }

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
            let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)
            // One standing agent for each pull request, living in its worktree (FR-017).
            let standing = pullRequest.map { state?.standingAgentIDs[$0.pull.number] }
                ?? state?.standingAgentID
            // A standing agent that is still here is picked back up. One that has gone
            // is replaced, and the replacement adopted, so a workflow whose agent was
            // archived last week is not dead — it simply starts again.
            if let standing, agents[standing] != nil, agents[standing]?.state != .archived {
                try await adoptAndPrompt(agentID: standing, prompt: prompt, workflow: workflow, run: run)
                return standing
            }
            let agentID = try await startAgent(for: workflow, run: run, prompt: prompt, pullRequest: pullRequest)
            records = workflowStore.load()
            records.update(folder: workflow.folder, workflowID: workflow.workflowID) {
                if let pullRequest {
                    $0.standingAgentIDs[pullRequest.pull.number] = agentID
                } else {
                    $0.standingAgentID = agentID
                }
            }
            workflowStore.save(records)
            return agentID

        case .new:
            return try await startAgent(for: workflow, run: run, prompt: prompt, pullRequest: pullRequest)
        }
    }

    /// A workflow that named a setting it cannot have.
    ///
    /// Typed, and thrown rather than returned, because it travels up through `runAgent`
    /// to `fire`'s existing `catch` — which used to turn everything into `.unreadable`.
    /// Matching on the type is what lets that `catch` tell this apart from a runtime
    /// that would not start; matching on the message would have been a sentence in two
    /// places, waiting to be reworded in one of them.
    struct SettingRefused: Error {
        var setting: String
        var detail: String
    }

    /// A start in the mode, on the runtime and with the model a workflow's file asks
    /// for — or a refusal, having started nothing at all. Shared by workflows and by an
    /// agent starting another (028), so `runtime:`, `model:` and `permission-mode:`
    /// mean one thing in both.
    ///
    /// The refusal cannot be decided before a session exists. Whether a runtime offers
    /// `plan` is a fact about a live session with that runtime, and there are only two
    /// other places it could come from, both wrong:
    ///
    /// `ACPSession.apply` swallows an option the runtime will not take, and it is right
    /// to. A person is looking at the control, the agent in front of them is worth more
    /// than the option that went missing, and they can see what happened. This path has
    /// nobody in the room at nine in the morning, and the option going missing is the
    /// sentence *this one may not change files*.
    ///
    /// `OptionCache` would answer without starting anything, and would be answering
    /// from what this runtime offered the last time somebody used it here. A stale
    /// entry still claiming plan mode is available is exactly the failure FR-008
    /// exists to prevent — the agent would start, the mode would not be sent, and
    /// nothing would say so.
    ///
    /// So the session is made first, and it is made as a `Draft`, which `start` then
    /// takes and reuses: one process, whether the settings are honoured or refused.
    ///
    /// `managesAgents` is whether the agent this makes may start agents of its own; it
    /// has to be known here because a session with settings is made now, as a draft,
    /// and its MCP server is fixed when it is made.
    func startRequest(settings: WorkflowSettings, folder: URL, prompt: String,
                      managesAgents: Bool) async throws -> DaemonAPI.StartRequest {
        let runtimeID = settings.runtimeID ?? RuntimeCatalog.builtIn[0].id
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else {
            // A runtime this version has never heard of. Not rehomed onto the default
            // one: a workflow that says `runtime: grok` and quietly runs on Claude is
            // the same betrayal as one that says `permission-mode: plan` and runs
            // without it (FR-009).
            throw SettingRefused(
                setting: WorkflowSettings.Setting.runtime,
                detail: "There is no runtime called \"\(runtimeID)\" — this version knows "
                    + RuntimeCatalog.builtIn.map(\.id).joined(separator: ", "))
        }

        if settings.isEmpty {
            // Today's path exactly, and no draft. Most workflows say nothing about how
            // they run, and for those there is nothing to check, so there is no reason
            // to make a session early or to keep one in hand (SC-006).
            return DaemonAPI.StartRequest(runtimeID: runtimeID, cwd: folder, prompt: prompt)
        }
        return try await settled(settings, folder: folder, runtime: runtime, prompt: prompt,
                                 managesAgents: managesAgents)
    }

    /// Start a new agent for a workflow, as its file says, and mark it as the
    /// workflow's.
    private func startAgent(for workflow: Workflow, run: WorkflowRun, prompt: String,
                            pullRequest: PullRequestFire? = nil) async throws -> UUID {
        var request = try await startRequest(settings: workflow.settings, folder: workflow.folder,
                                             prompt: prompt, managesAgents: true)
        // A pull request's run works in its worktree, and is filed under the project as
        // any agent in a worktree is (030). The project folder needs nothing extra.
        if let worktree = pullRequest?.pull.worktree, !worktree.isProjectFolder {
            request.worktree = .existing(worktree.checkout)
        }
        let agentID = try await start(request)
        if var agent = agents[agentID] {
            agent.startedByWorkflow = workflow.workflowID
            agent.startedByRun = run.id
            agent.title = pullRequest.map { "\(workflow.name) · #\($0.pull.number)" } ?? workflow.name
            changed(agent)
        }
        return agentID
    }

    /// Make the session, ask it what it offers, and turn the file's words into a start
    /// — or throw, having started nothing and left no agent behind.
    private func settled(_ settings: WorkflowSettings, folder: URL, runtime: Runtime,
                         prompt: String, managesAgents: Bool) async throws -> DaemonAPI.StartRequest {
        let draftID = UUID()
        let pending = Task { [self] in
            try await freshSession(runtimeID: runtime.id, cwd: folder, mcpServers: [],
                                   managesAgents: managesAgents)
        }
        let draft = Draft(runtimeID: runtime.id, cwd: folder,
                          mcpServers: [], pending: pending, managesAgents: managesAgents)
        drafts[draftID] = draft

        let made: DaemonCore.MadeSession
        do {
            made = try await pending.value
        } catch {
            // The runtime would not start. Nothing to let go of but the entry itself,
            // and the error is the runtime's own — this is not a refused setting, and
            // `fire` should keep saying what it has always said about it.
            drafts.removeValue(forKey: draftID)
            throw error
        }

        // The authoritative list, from `session/new` — what this runtime, in this
        // folder, is offering right now.
        let advertised = await made.session.options
        switch WorkflowSettings.resolve(settings, against: advertised) {
        case .refused(let setting, let value, let offered):
            // No agent is created. The session that was made to ask the question is
            // ended, because nothing is going to use it.
            drafts.removeValue(forKey: draftID)
            await endDraft(draft)
            throw SettingRefused(
                setting: setting,
                detail: WorkflowSettings.refusalDetail(setting: setting, value: value,
                                                       offered: offered, runtime: runtime.name))
        case .resolved(let options):
            // The same session, handed on. `start` takes the draft by this id and
            // reuses it, so asking what the runtime offered costs no second process.
            return DaemonAPI.StartRequest(runtimeID: runtime.id, cwd: folder,
                                          prompt: prompt, startOptions: options,
                                          draftID: draftID)
        }
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
    func record(_ outcome: WorkflowOutcome, for workflow: Workflow,
                causingEvent: EventPosition? = nil, depth: Int = 0) {
        var records = workflowStore.load()
        records.record(outcome, folder: workflow.folder, workflowID: workflow.workflowID,
                       causingEvent: causingEvent)
        workflowStore.save(records)
        broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow, records: records))
        // On the log (042): what the fire came to, on the event that caused it, and as
        // an event of its own, one step deeper in the chain.
        switch outcome {
        case .ran(let agentID, _):
            if let causingEvent {
                addConsequence(.fired(workflowID: workflow.workflowID, folder: workflow.folder, agentID: agentID),
                               to: causingEvent)
            }
            raise(EventDraft(name: "workflow.ran", at: now(), scope: .project(folder: workflow.folder),
                             sentence: "Workflow \(workflow.name) started \(LeaseWords.agentName(agents[agentID]?.title)).",
                             details: ["workflow": workflow.workflowID, "agent": agentID.uuidString,
                                       "agent_title": agents[agentID]?.title ?? "Untitled"],
                             chainDepth: depth + 1))
        case .refused(let refusal, _, _):
            if let causingEvent {
                addConsequence(.refused(workflowID: workflow.workflowID, folder: workflow.folder, reason: refusal),
                               to: causingEvent)
            }
            raise(EventDraft(name: "workflow.refused", at: now(), scope: .project(folder: workflow.folder),
                             sentence: "Workflow \(workflow.name) did not run: \(refusal.message).",
                             details: ["workflow": workflow.workflowID, "reason": refusal.message],
                             chainDepth: depth + 1))
        }
    }

    /// An event as the workflow row says it: "pull_request.merged #41".
    static func eventLabel(_ event: Event) -> String {
        EventPattern.matching(event).label
    }

    // MARK: What an agent doing something sets off

    /// How deep a fire caused by this agent would be.
    ///
    /// One deeper than the run that produced the agent; zero for an agent nobody
    /// automated. Read *before* the run is released, because releasing it is what makes
    /// a finished agent's depth unfindable — and a depth that silently resets to zero is
    /// a loop the limit never stops.
    func workflowChainDepth(causedBy agentID: UUID) -> Int {
        guard let (_, run) = runInFlight(for: agentID) else {
            // An agent another agent started has no run of its own, but it is still
            // part of whatever chain its starter is in (028). Without this, a workflow
            // whose agent starts one that fires the same workflow again would begin
            // again at depth zero every time round — the loop the limit exists for.
            // Taken when the agent was made, because the starter's run may be over by
            // now (see `Agent.chainDepth`). Read off the starter only for a record from
            // before that was kept. One step only: an agent another agent started
            // cannot start one itself.
            if let depth = agents[agentID]?.chainDepth { return depth }
            if let starter = agents[agentID]?.startedByAgent, starter != agentID {
                return workflowChainDepth(causedBy: starter)
            }
            return 0
        }
        return run.depth + 1
    }

    /// The run in flight that this agent is doing the work of, if any.
    ///
    /// By the agent's own `startedByRun` — and, only when the agent carries none, by the
    /// run's `agentID`. The second is for one window and nothing else (025): the run is
    /// written the moment its agent is known, and the agent's record, which names the run
    /// back, a moment later by a queued task. A daemon killed between the two leaves a
    /// run pointing at an agent that does not point back, and without this that run is
    /// never found again — it holds its workflow as "a run is still going" for a week,
    /// and nothing waiting on it ever hears. Never consulted when `startedByRun` is set,
    /// so an agent reused down a chain cannot be matched to a run that is not its own.
    func runInFlight(for agentID: UUID) -> (key: String, run: WorkflowRun)? {
        guard let agent = agents[agentID] else { return nil }
        if let runID = agent.startedByRun {
            return workflowRuns.first { $0.value.id == runID }.map { ($0.key, $0.value) }
        }
        return workflowRuns.first { $0.value.agentID == agentID }.map { ($0.key, $0.value) }
    }

    /// Called from the one funnel every agent state change goes through.
    func workflowsRespond(to event: WorkflowAgentEvent, agentID: UUID, depth: Int? = nil,
                          causingEvent: EventPosition? = nil) {
        guard let agent = agents[agentID] else { return }
        // Before anything is read off `workflows`, because at this point that
        // dictionary is empty and the guard below would swallow the event without
        // leaving a trace. See `deferredLifecycleEvents` for why the whole of this
        // problem exists.
        guard workflowsAreStarted else {
            deferredLifecycleEvents.append(
                (event: event, agentID: agentID,
                 depth: depth ?? workflowChainDepth(causedBy: agentID), cause: causingEvent))
            return
        }
        let folder = agent.projectFolder
        guard let byID = workflows[folder], !byID.isEmpty else { return }
        let depth = depth ?? workflowChainDepth(causedBy: agentID)
        let records = workflowStore.load()

        let trigger: WorkflowTrigger
        switch event {
        case .finished: trigger = .agentFinished
        case .askedPermission: trigger = .agentAskedPermission
        case .askedForm: trigger = .agentAskedForm
        case .stopped: trigger = .agentStopped
        }

        for workflow in byID.values where workflow.responds(to: event)
            && records.state(folder: folder, workflowID: workflow.workflowID)?.isArchived != true {
            // Detached, because this is called from inside the actor by `move`, and
            // firing awaits things that can call back into it. The shape `beginTurn`
            // already uses for a turn.
            Task { [weak self] in
                await self?.fire(workflow, on: trigger,
                                 triggeringAgentID: agentID, depth: depth, causingEvent: causingEvent)
            }
        }
    }

    /// A run is over. Release the workflow, and let anything chained off it go.
    func workflowRunFinished(agentID: UUID) {
        guard let (key, run) = runInFlight(for: agentID) else { return }
        workflowRuns.removeValue(forKey: key)
        persistWorkflowRuns()
        // A pull request's run is over: look at it again soon, and fire then on any
        // change that arrived while it ran (FR-014).
        if run.pullRequest != nil { pullRequestRunEnded(in: run.folder) }
        if let workflow = workflow(run.workflowID, in: run.folder) {
            broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow))
        }

        let folder = Project.standardize(run.folder)
        // On the log (042), a step deeper than the run, as the old trigger fires.
        raise(EventDraft(name: "workflow.completed", at: now(), scope: .project(folder: folder),
                         sentence: "Workflow \(workflow(run.workflowID, in: run.folder)?.name ?? run.workflowID) finished.",
                         details: ["workflow": run.workflowID]
                            .merging(run.agentID.map { ["agent": $0.uuidString,
                                                         "agent_title": agents[$0]?.title ?? "Untitled"] } ?? [:]) { $1 },
                         chainDepth: run.depth + 1))
        guard let byID = workflows[folder] else { return }
        let records = workflowStore.load()
        for other in byID.values where other.respondsToCompletion(of: run.workflowID)
            && records.state(folder: folder, workflowID: other.workflowID)?.isArchived != true {
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
    /// obeys every other rule — the run in flight, the ceilings, the archive —
    /// returning the refusal on the summary rather than swallowing it. Somebody is
    /// watching when they tap this, so being told why matters more here than anywhere.
    public func runWorkflow(_ request: DaemonAPI.WorkflowRequest) async throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        // A pull-request workflow's run always has a pull request, and Run now names
        // none (038 contract).
        if workflow.onlyRespondsToPullRequests {
            record(.refused(.noPullRequest, at: Date(), repeats: 1), for: workflow)
            return summary(for: workflow)
        }
        await fire(workflow, on: .schedule(WorkflowSchedule()))
        return summary(for: workflow)
    }

    /// Put one away, or bring it back.
    ///
    /// The counterweight to an agent writing a workflow without asking first, and the
    /// reason it can. Not a delete: the file stays in the project, where it is still a
    /// file somebody can read, edit or commit — the app simply stops acting on it, and
    /// says so on the row rather than making the workflow disappear.
    ///
    /// It is also the whole of holding a workflow. There was a pause beside this, and
    /// it earned nothing: two switches that both mean "do not run this", one of them
    /// reversible in exactly the same tap as the other. Archiving says the same thing
    /// and says where the row went.
    public func archiveWorkflow(_ request: DaemonAPI.WorkflowArchiveRequest) throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        var records = workflowStore.load()
        records.update(folder: request.folder, workflowID: request.workflowID) {
            $0.isArchived = request.archived
            // What it last did belonged to the life it had before. Keeping it would
            // leave a restored workflow wearing a refusal from a fortnight ago.
            $0.lastOutcome = nil
        }
        workflowStore.save(records)
        let summary = summary(for: workflow, records: records)
        broadcast(DaemonAPI.Notification.workflowChanged, summary)
        return summary
    }

    /// Change what a workflow is allowed to do, by writing its own file.
    ///
    /// The one place in this app that edits a document a person wrote, which is why
    /// every step of it refuses rather than doing its best, and why nothing is written
    /// until every key has been applied to the text in hand. A file half-edited
    /// and then refused would be worse than one not edited at all: the person would be
    /// left with a change they did not ask for and no message saying what happened.
    public func setWorkflowSettings(_ request: DaemonAPI.WorkflowSettingsRequest) throws -> WorkflowSummary {
        guard let existing = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        let url = WorkflowFile.url(for: existing.workflowID, in: existing.folder)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "\(url.lastPathComponent) could not be read.")
        }

        // A key the caller left out is removed. The page sends what it is showing, so
        // "no mode" is a thing it can say, and saying it has to take the line out
        // rather than leave the old one behind.
        var edited = original
        do {
            for (key, value) in [(WorkflowSettings.Setting.permissionMode, request.settings.permissionMode),
                                 (WorkflowSettings.Setting.runtime, request.settings.runtimeID),
                                 (WorkflowSettings.Setting.model, request.settings.model),
                                 (WorkflowSettings.Setting.effort, request.settings.effort)] {
                edited = try FrontMatterEdit.set(key, to: value, in: edited)
            }
            // Only the ones that differ, in id order: a key left as it was is not
            // touched, so its line, its quoting and its comment stay the author's.
            let ids = Set(existing.settings.options.keys).union(request.settings.options.keys)
            for id in ids.sorted() where existing.settings.options[id] != request.settings.options[id] {
                edited = try FrontMatterEdit.set(id, under: WorkflowSettings.Setting.options,
                                                 to: request.settings.options[id], in: edited)
            }
        } catch let refusal as FrontMatterEdit.Refusal {
            // The editor's own sentence, unchanged. It is the one that knows what it
            // found, and nothing was written (FR-025).
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable, message: refusal.message)
        }

        do {
            try Data(edited.utf8).write(to: url, options: .atomic)
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "\(url.lastPathComponent) could not be written: \(error.localizedDescription)")
        }

        // Synchronously, and not through the watcher. The watcher is debounced by
        // 250ms and will fire anyway and find nothing changed; waiting that long to
        // tell the window what it just asked for is the kind of lag that reads as the
        // app having ignored you. The rescan also broadcasts to every other window.
        rescanWorkflows(in: existing.folder)
        guard let reread = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "\(request.workflowID) went while it was being changed.")
        }
        return summary(for: reread)
    }
}

// MARK: - Runs that outlive the daemon (025 US3)

extension DaemonCore {
    /// Read back the runs the last daemon had in flight.
    ///
    /// Called from the top of `recover()`, before anything is moved — and that order is
    /// the one thing here that must not be tidied. Recovery defers each lifecycle event
    /// it raises **with its depth computed at that moment**, from `workflowRuns`; loaded
    /// any later, every one of them is recorded at depth zero and the ceiling this exists
    /// to keep is lost in the act of keeping it. (Today recovery raises no such event —
    /// every agent it finds is about to be picked back up, and says nothing — but that is
    /// a fact about 011's rules, and the order should not depend on it staying true.)
    ///
    /// Only loaded, not judged. Whether a run can still complete depends on the agents
    /// and the workflow files, which are not read yet; `pruneWorkflowRuns()` decides that
    /// once they are.
    func loadWorkflowRuns() {
        for run in workflowStore.load().runs {
            // Keyed as `Workflow.id` is, from a folder standardised the same way. The
            // record was standardised when it was written, but a file is only text.
            let folder = Project.standardize(run.folder)
            workflowRuns[folder.path + "/" + run.runKey] = run
        }
    }

    /// Write the runs in flight, whenever they move.
    ///
    /// The whole file is read and written, as every writer of it does, so the states and
    /// the tick beside the runs go back exactly as they were. Sorted, so a file compared
    /// by eye — or by `git diff` on somebody's root — does not reorder itself each time.
    func persistWorkflowRuns() {
        var records = workflowStore.load()
        records.runs = workflowRuns.values.sorted {
            ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString)
        }
        workflowStore.save(records)
    }

    /// Let go of every restored run that cannot complete, and fire nothing for it.
    ///
    /// Nothing waiting on one of these is told it finished, because it did not: the app
    /// would be inventing a completion nobody saw (FR-012). A run is kept only if its
    /// workflow is still there, it is younger than `WorkflowRecords.runHorizon`, and its
    /// agent is still going to carry on — working, or about to be picked back up.
    ///
    /// That last rule is wider than "the agent still exists", on purpose. An agent can
    /// finish and have its record written, and the daemon go before the run it belonged
    /// to is let go; restored, that run would wait for a finish that has already
    /// happened, and refuse its workflow as "a run is still going" for a week. It is
    /// released like the others. Whether its completion should have fired a chain is not
    /// something the daemon can now honestly say, so it says nothing.
    func pruneWorkflowRuns() {
        let now = now()
        var released: [WorkflowRun] = []
        for (key, run) in workflowRuns {
            let agentID = run.agentID ?? agents.values.first { $0.startedByRun == run.id }?.id
            let agent = agentID.flatMap { agents[$0] }
            let why: String?
            if now.timeIntervalSince(run.startedAt) >= WorkflowRecords.runHorizon {
                why = "it was more than a week old"
            } else if workflow(run.workflowID, in: run.folder) == nil {
                why = "its workflow is no longer there"
            } else if let agent {
                if agent.state == .archived {
                    why = "its agent was archived"
                } else if agent.state.holdsRuntime || agent.mayBePickedUpAfterRestart {
                    why = nil
                } else {
                    why = "its agent had already ended"
                }
            } else {
                why = "its agent is gone"
            }
            guard let why else { continue }
            workflowRuns.removeValue(forKey: key)
            released.append(run)
            DaemonLog.shared.write("let go of the \(run.workflowID) run from before the restart: \(why)")
        }
        guard !released.isEmpty else { return }
        persistWorkflowRuns()
        for run in released {
            if let workflow = workflow(run.workflowID, in: run.folder) {
                broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow))
            }
        }
    }
}
