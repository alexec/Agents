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
        // Helper limits kept in projects.json before #126, into each project's file once.
        migrateHelperLimitsToProjectFiles()
        for project in allProjects(includeArchived: false) where project.exists {
            adoptWorkflows(in: project.folder)
        }
        // The switches and archives kept here before #125, into their files once. After
        // adoption, so the files are read, and before approval begins, so a first start
        // approves the files as they will stand.
        migrateWorkflowSwitchesToFiles()
        // After adoption, because a run is judged against the workflow files, and before
        // the held events are replayed, so nothing they fire collides with a run that is
        // already over.
        pruneWorkflowRuns()
        // After adoption, so every file already here is what gets approved as it stands.
        beginWorkflowApprovalsIfNeeded()
        // And the projects' plugins, on the same terms (security review, S2).
        beginPluginApprovalsIfNeeded()
        beginMCPApprovalsIfNeeded()
        // Folders that went while the daemon was away, marked before the first tick (#119).
        await noteMissingFolders()
        startWorkflowTicker()
        workflowsAreStarted = true
        // Whatever happened while this layer could not act, now, and in the order it
        // happened — which for a restart is `recover`'s order, most recently active
        // first. Taken out of the array before any of it is replayed, so an event that
        // somehow defers again lands on an empty queue instead of a growing one.
        let waiting = deferredLifecycleEvents
        deferredLifecycleEvents.removeAll()
        for held in waiting {
            workflowsRespond(to: held.event, agentID: held.agentID, depth: held.depth, causingEvent: held.cause,
                             endingRun: held.endingRun)
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
        watchBranches(in: standardized)
        let held = workflows[standardized]?.values ?? [:].values
        guard !held.isEmpty else { return }
        // Read once for the lot rather than once each: this is a file read, and a
        // project may hold a few dozen workflows.
        let records = workflowStore.load()
        let ceilings = workflowCeilings(records: records)
        for workflow in held {
            broadcast(DaemonAPI.Notification.workflowChanged,
                      summary(for: workflow, records: records, ceilings: ceilings))
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
            Task {
                await self?.scheduleWorkflowRescan(in: standardized)
                // The same watch sees the Dashboard's tile files change by hand or by a pull (074).
                await self?.dashboardFilesChanged(changed, in: standardized)
                // And the project's own settings file (#126).
                await self?.projectConfigFilesChanged(changed, in: standardized)
            }
        }
    }

    /// Stop watching everything. Called as the daemon goes.
    func stopWatchingAllWorkflows() {
        for (_, watch) in workflowWatchers { watch.stop() }
        workflowWatchers.removeAll()
        stopWatchingAllBranches()
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

        let moved = Set(after.keys.filter { before[$0] != after[$0] })
        let gone = before.keys.filter { after[$0] == nil }
        for id in gone {
            broadcast(DaemonAPI.Notification.workflowRemoved,
                      DaemonAPI.WorkflowRemovedNotification(folder: standardized, workflowID: id))
        }
        guard !moved.isEmpty || !gone.isEmpty else { return }
        // Every one, not only those whose file moved: a file arriving, changing or going
        // can move another across the waiting ceiling (#132).
        rebroadcastWorkflows(in: standardized)
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
        let ceilings = workflowCeilings(records: records)
        return folders
            .flatMap { workflows[$0]?.values ?? [:].values }
            .map { summary(for: $0, records: records, ceilings: ceilings) }
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
    func summary(for workflow: Workflow, records: WorkflowRecords? = nil,
                 ceilings: WorkflowCeilings? = nil) -> WorkflowSummary {
        let records = records ?? workflowStore.load()
        let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)
        let archived = workflow.isArchived
        let enabled = !workflow.isOff
        let overLimit = archived ? nil : limitReached(by: workflow, records: records, ceilings: ceilings)
        // A file waiting for the person has no next run: nothing fires until they approve.
        let waiting = archived ? nil : awaitingApproval(workflow, state: state, records: records)
        let runs = !archived && enabled && overLimit == nil && waiting == nil && workflow.problem == nil
        let now = self.now()
        return WorkflowSummary(
            workflow: workflow,
            isArchived: archived,
            isEnabled: enabled,
            overLimit: overLimit,
            nextFireAt: runs ? workflow.nextDue(after: now) : nil,
            lastOutcome: state?.lastOutcome,
            isRunning: isRunning(workflow),
            causingEvent: state?.lastCausingEvent,
            causingEventName: state?.lastCausingEvent.flatMap { eventLog.event(at: $0) }.map(Self.eventLabel),
            awaitingApproval: waiting,
            lastFiredAt: state?.lastFiredAt,
            lastFiredBy: state?.lastFiredBy,
            nextFireAtByTrigger: runs ? workflow.triggers.map { $0.schedule?.nextDue(after: now) } : [],
            cooldownEndsAt: workflow.cooldownEnds(after: state?.lastFiredAt, now: now),
            holdsAFire: state?.heldFire != nil,
            offReason: WorkflowState.offReason(workflow, state,
                                               digest: enabled ? nil : workflowDigest(workflow)))
    }

    /// Whether a run of it is in flight.
    func isRunning(_ workflow: Workflow) -> Bool {
        workflowRuns[workflow.id] != nil
    }

    /// Where every workflow stands against the two ceilings, worked out once (#132).
    ///
    /// The per-project ceiling counts only workflows waiting for the person's OK: the
    /// worry is a queue nobody reviewed, and a workflow somebody approved is not that.
    /// The total counts the approved ones, which are the ones that can run.
    ///
    /// By name rather than by age, and by project path rather than by when a project
    /// was added, because a folder has no reliable age — a checkout writes every file
    /// at the same instant — and because two machines looking at the same work have to
    /// come out with the same list.
    ///
    /// Archived workflows are in neither. That is why archiving makes room: it is the
    /// one move that changes these lists without deleting anybody's file.
    struct WorkflowCeilings {
        /// Each project's waiting workflows by file name; the first few may wait.
        var waiting: [URL: [String]] = [:]
        /// Approved and not archived, in the order the total is applied.
        var approved: [(folder: URL, workflowID: String)] = []

        /// The waiting ones a project is allowed, which are the ones that can be approved.
        func mayWait(in folder: URL) -> ArraySlice<String> {
            (waiting[folder] ?? []).prefix(WorkflowLimit.project.allowed)
        }
    }

    /// Read once for a whole listing: deciding whether a workflow waits reads its file.
    func workflowCeilings(records: WorkflowRecords) -> WorkflowCeilings {
        var ceilings = WorkflowCeilings()
        for folder in workflows.keys.sorted(by: { $0.path < $1.path }) {
            for id in (workflows[folder] ?? [:]).keys.sorted() {
                guard let workflow = workflows[folder]?[id] else { continue }
                let state = records.state(folder: folder, workflowID: id)
                guard !workflow.isArchived else { continue }
                if awaitingApproval(workflow, state: state, records: records) != nil {
                    ceilings.waiting[folder, default: []].append(id)
                } else {
                    ceilings.approved.append((folder: folder, workflowID: id))
                }
            }
        }
        return ceilings
    }

    /// Which ceiling, if either, this workflow is past. Archived ones are past neither:
    /// they are out of the way, which is the point of archiving.
    ///
    /// A waiting one is only ever past its project's: it runs nothing until approved,
    /// so the total has nothing to say about it. An approved one is only ever past the
    /// total: a project may hold as many approved workflows as the machine allows.
    func limitReached(by workflow: Workflow, records: WorkflowRecords,
                      ceilings: WorkflowCeilings? = nil) -> WorkflowLimit? {
        guard !workflow.isArchived else { return nil }
        let ceilings = ceilings ?? workflowCeilings(records: records)
        if ceilings.waiting[workflow.folder]?.contains(workflow.workflowID) == true {
            return ceilings.mayWait(in: workflow.folder).contains(workflow.workflowID) ? nil : .project
        }
        let live = ceilings.approved.prefix(WorkflowLimit.total.allowed)
        return live.contains { $0.folder == workflow.folder && $0.workflowID == workflow.workflowID }
            ? nil : .total
    }

    /// Tell the windows about every other workflow in a project, after something that
    /// can move one across a ceiling: approving, archiving or removing a waiting one
    /// lets the next in line be approved.
    func rebroadcastWorkflows(in folder: URL, except: Set<String> = []) {
        let standardized = Project.standardize(folder)
        let records = workflowStore.load()
        let ceilings = workflowCeilings(records: records)
        for (id, workflow) in workflows[standardized] ?? [:] where !except.contains(id) {
            broadcast(DaemonAPI.Notification.workflowChanged,
                      summary(for: workflow, records: records, ceilings: ceilings))
        }
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

        // Folders gone since the last look: a worktree removed after a merge shows on
        // its row before anybody types into it (#119).
        await noteMissingFolders()

        // Allowances whose time to come back has come, and grants past their date (052).
        settleAllowanceClocks(now: now)
        checkDueAllowances(now: now)

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

        // Before the guard below, like the blocks above: a fire held across a restart is
        // still owed its one run, and the first tick after starting is when to give it.
        await releaseHeldWorkflowFires(now: now)

        var records = workflowStore.load()
        let since = records.lastTickAt
        records.lastTickAt = now
        keepQuietly("workflow history") { try workflowStore.save(records) }

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
                guard !workflow.isArchived else { continue }
                // Turned off is recorded, unlike archived (#100): the workflow is still
                // on the list, and its row saying how many times it did not run is how
                // somebody notices it has been off since Tuesday. Repeats count up on
                // one line, so this is one line however long it stays off.
                if workflow.isOff {
                    record(.refused(.disabled, at: now, repeats: 1), for: workflow)
                } else if wasAway {
                    record(.refused(.missedWhileClosed, at: now, repeats: 1), for: workflow)
                } else {
                    // The schedule that came due, so the page can say which one ran it.
                    let schedule = workflow.schedules.first {
                        $0.nextDue(after: since).map { $0 <= now } ?? false
                    } ?? WorkflowSchedule()
                    await fire(workflow, on: .schedule(schedule), at: now)
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
              at when: Date? = nil,
              causingEvent: EventPosition? = nil,
              byHand: Bool = false) async -> WorkflowRefusal? {
        let now = when ?? self.now()
        let key = workflow.id
        let records = workflowStore.load()
        let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)

        var triggeringAgentIsUsable: Bool?
        if workflow.mode == .triggering, let triggeringAgentID {
            triggeringAgentIsUsable = agents[triggeringAgentID]?.state != .archived
                && agents[triggeringAgentID] != nil
        }

        // Behind archiving, which is the person's own decision and says more; ahead of
        // everything else, because nothing else matters about a file nobody has seen.
        // Turning off is the same kind of decision, and stops a trigger the same way; Run
        // now is not a trigger, and runs an off workflow so it can be tried (#100).
        let disabled = !byHand && workflow.isOff
        if !workflow.isArchived, !disabled,
           awaitingApproval(workflow, state: state, records: records) != nil {
            let refusal = WorkflowRefusal.awaitingApproval
            record(.refused(refusal, at: now, repeats: 1), for: workflow, causingEvent: causingEvent, depth: depth)
            return refusal
        }

        if let refusal = workflow.refusalIfBlocked(
            isRunning: workflowRuns[key] != nil,
            depth: depth,
            isArchived: workflow.isArchived,
            isDisabled: disabled,
            overLimit: limitReached(by: workflow, records: records),
            dayLimitReached: isDayLimitReached(),
            folderExists: Self.isDirectory(workflow.folder),
            triggeringAgentIsUsable: triggeringAgentIsUsable,
            lastStartedAt: state?.lastFiredAt,
            now: now,
            byHand: byHand) {
            if case .coolingDown = refusal {
                // Held rather than dropped (#103): this one replaces any held before it,
                // so a burst comes to one run with the last of its triggers, which is
                // usually the one that matters.
                hold(HeldWorkflowFire(trigger: trigger, triggeringAgentID: triggeringAgentID, depth: depth,
                                      causingEvent: causingEvent, heldAt: now), for: workflow)
            }
            record(.refused(refusal, at: now, repeats: 1), for: workflow, causingEvent: causingEvent, depth: depth)
            return refusal
        }

        var run = WorkflowRun(workflowID: workflow.workflowID, folder: workflow.folder,
                              trigger: trigger, triggeringAgentID: triggeringAgentID,
                              depth: depth, startedAt: now)
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
            let agentID = try await runAgent(for: workflow, run: run)
            run.agentID = agentID
            workflowRuns[key] = run
            persistWorkflowRuns()
            record(.ran(agentID: agentID, at: now), for: workflow, causingEvent: causingEvent, depth: depth,
                   cause: byHand ? .byHand : .trigger(trigger))
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
            return refusal
        } catch {
            workflowRuns.removeValue(forKey: key)
            persistWorkflowRuns()
            let message = (error as? JSONRPCError)?.message ?? error.localizedDescription
            record(.refused(.unreadable(message), at: now, repeats: 1), for: workflow, causingEvent: causingEvent, depth: depth)
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
            let state = records.state(folder: workflow.folder, workflowID: workflow.workflowID)
            let standing = state?.standingAgentID
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
            keepQuietly("this workflow's settings") { try workflowStore.save(records) }
            return agentID

        case .new:
            return try await startAgent(for: workflow, run: run, prompt: prompt)
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
    ///
    /// A runtime that is named and cannot take an agent here — not installed, not
    /// signed in, out of the pool — is refused before anything starts, naming the ones
    /// that can (#117). `checksDefault` asks the same of the default runtime when none
    /// is named: an agent starting one is told; a workflow that names none is left as
    /// it always was, because a refusal of a `runtime:` its file never wrote would send
    /// the person to the wrong line.
    func startRequest(settings: WorkflowSettings, folder: URL, prompt: String,
                      managesAgents: Bool, checksDefault: Bool = false) async throws -> DaemonAPI.StartRequest {
        let runtimeID = settings.runtimeID ?? RuntimeCatalog.defaultRuntime.id
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
        if settings.runtimeID != nil || checksDefault, let refusal = unavailableRuntimeRefusal(runtime) {
            throw SettingRefused(setting: WorkflowSettings.Setting.runtime, detail: refusal)
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
    private func startAgent(for workflow: Workflow, run: WorkflowRun, prompt: String) async throws -> UUID {
        var request = try await startRequest(settings: workflow.settings, folder: workflow.folder,
                                             prompt: prompt, managesAgents: true)
        request.labels = workflow.settings.labels
        let agentID = try await start(request, startedBy: nil, labelOwner: .agent,
                                      workflow: (workflow.workflowID, run.id))
        if var agent = agents[agentID] {
            agent.title = workflow.name
            changed(agent)
        }
        return agentID
    }

    /// Make the session, ask it what it offers, and turn the file's words into a start
    /// — or throw, having started nothing and left no agent behind.
    private func settled(_ settings: WorkflowSettings, folder: URL, runtime: Runtime,
                         prompt: String, managesAgents: Bool) async throws -> DaemonAPI.StartRequest {
        let draftID = UUID()
        // A workflow's agent follows the runtime's default (064, FR-011).
        let sandbox = resolveSandbox(runtimeID: runtime.id, override: nil, starter: nil).choice
        let pending = Task { [self] in
            try await freshSession(runtimeID: runtime.id, cwd: folder, mcpServers: [],
                                   managesAgents: managesAgents, sandbox: sandbox)
        }
        let draft = Draft(runtimeID: runtime.id, cwd: folder,
                          mcpServers: [], personalServers: PersonalDotAgents.mcpStamp(home: locations.personalHome),
                          pending: pending, managesAgents: managesAgents, sandbox: sandbox)
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
            // Offered is not taken (#143). What a runtime offers can hang on the model:
            // Claude lists Auto and an effort in `session/new`, and on haiku has
            // neither — the effort is refused, and Auto comes back as Accept edits with
            // no error. So the settings are set here, on the draft, and read back; one
            // the runtime would not keep refuses the run as one it never offered does.
            if let refusal = await made.session.apply(options).first {
                drafts.removeValue(forKey: draftID)
                await endDraft(draft)
                throw SettingRefused(setting: Self.settingName(refusal.id, in: advertised),
                                     detail: Self.notKeptDetail(refusal, in: advertised,
                                                                runtime: runtime.name))
            }
            // The same session, handed on. `start` takes the draft by this id and
            // reuses it, so asking what the runtime offered costs no second process.
            return DaemonAPI.StartRequest(runtimeID: runtime.id, cwd: folder,
                                          prompt: prompt, startOptions: options,
                                          draftID: draftID)
        }
    }

    /// The file's name for an advertised option: `permission-mode` for the mode,
    /// `model`, `effort`, and the option's own id for the rest, as `resolve` refuses.
    static func settingName(_ id: String, in advertised: [ConfigOption]) -> String {
        if id == ModeMemory.modeOption(in: advertised)?.id { return WorkflowSettings.Setting.permissionMode }
        if id == WorkflowSettings.modelOption(in: advertised)?.id { return WorkflowSettings.Setting.model }
        if id == WorkflowSettings.effortOption(in: advertised)?.id { return WorkflowSettings.Setting.effort }
        return id
    }

    /// The sentence for a setting the runtime offered and then would not keep.
    static func notKeptDetail(_ refusal: ACPSession.RefusedOption, in advertised: [ConfigOption],
                              runtime: String) -> String {
        let asked = refusal.value.stringValue ?? "\(refusal.value)"
        let setting = settingName(refusal.id, in: advertised)
        if let instead = refusal.instead {
            return "\(runtime) offers \"\(asked)\" for \(setting) but would not keep it with the rest of "
                + "this file's settings — it switched to \"\(instead.stringValue ?? "\(instead)")\""
        }
        let why: String
        if let error = refusal.error as? JSONRPCError {
            why = error.data?["details"]?.stringValue ?? error.message
        } else {
            why = "\(refusal.error)"
        }
        return "\(runtime) would not take \"\(asked)\" for \(setting) with the rest of this file's settings: \(why)"
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
                causingEvent: EventPosition? = nil, depth: Int = 0, cause: WorkflowCause? = nil) {
        var records = workflowStore.load()
        records.record(outcome, folder: workflow.folder, workflowID: workflow.workflowID,
                       causingEvent: causingEvent, cause: cause)
        keepQuietly("workflow history") { try workflowStore.save(records) }
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
            // Not raised for a workflow turned off: it is the person's own decision, not
            // news, and a schedule turned off would put it on the log every half hour.
            // The row's count and the causing event's consequence still say it.
            // Nor for a trigger held by a cooldown (#103): it has not been refused, only
            // put off, and its run says so when it happens.
            guard refusal != .disabled else { return }
            if case .coolingDown = refusal { return }
            raise(EventDraft(name: "workflow.refused", at: now(), scope: .project(folder: workflow.folder),
                             sentence: "Workflow \(workflow.name) did not run: \(refusal.message).",
                             details: ["workflow": workflow.workflowID, "reason": refusal.code],
                             chainDepth: depth + 1))
        }
    }

    /// An event as the workflow row says it: "workflow.completed workflow nightly".
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

    /// Whether this agent is one of the workflow's own, whose news must not fire it (#102).
    ///
    /// Its own is the agent doing the run's work right now — read before the run is
    /// released, as the depth is, and handed in as `endingRun` once it has been — and,
    /// for a workflow that starts or keeps its agent, that agent for good: the person
    /// prompting it again later is still not news the workflow asked for. A triggering
    /// workflow's agent is somebody else's, borrowed for one run, and is news again once
    /// that run is over. An agent one of these started is the workflow's too.
    ///
    /// No opting in. A workflow that wants to go round again on its own agent's finish
    /// would only reach the chain-depth limit; the agent itself can carry on instead.
    func isOwnAgent(_ agentID: UUID, of workflow: Workflow, endingRun: String? = nil) -> Bool {
        if endingRun == workflow.id || runInFlight(for: agentID)?.key == workflow.id { return true }
        guard let agent = agents[agentID] else { return false }
        if workflow.mode != .triggering, agent.startedByWorkflow == workflow.workflowID { return true }
        // One step only, as `workflowChainDepth` goes: a helper cannot start one itself.
        guard let starter = agent.startedByAgent, starter != agentID else { return false }
        if runInFlight(for: starter)?.key == workflow.id { return true }
        return workflow.mode != .triggering && agents[starter]?.startedByWorkflow == workflow.workflowID
    }

    /// Called from the one funnel every agent state change goes through.
    func workflowsRespond(to event: WorkflowAgentEvent, agentID: UUID, depth: Int? = nil,
                          causingEvent: EventPosition? = nil, endingRun: String? = nil) {
        guard let agent = agents[agentID] else { return }
        // Before anything is read off `workflows`, because at this point that
        // dictionary is empty and the guard below would swallow the event without
        // leaving a trace. See `deferredLifecycleEvents` for why the whole of this
        // problem exists.
        guard workflowsAreStarted else {
            deferredLifecycleEvents.append(
                (event: event, agentID: agentID,
                 depth: depth ?? workflowChainDepth(causedBy: agentID), cause: causingEvent,
                 endingRun: endingRun ?? runInFlight(for: agentID)?.key))
            return
        }
        let folder = agent.projectFolder
        guard let byID = workflows[folder], !byID.isEmpty else { return }
        let depth = depth ?? workflowChainDepth(causedBy: agentID)

        let trigger: WorkflowTrigger
        switch event {
        case .finished: trigger = .agentFinished
        case .askedPermission: trigger = .agentAskedPermission
        case .askedForm: trigger = .agentAskedForm
        case .stopped: trigger = .agentStopped
        }

        for workflow in byID.values where workflow.responds(to: event)
            && !workflow.isArchived
            && !isOwnAgent(agentID, of: workflow, endingRun: endingRun) {
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
        if let workflow = workflow(run.workflowID, in: run.folder) {
            broadcast(DaemonAPI.Notification.workflowChanged, summary(for: workflow))
            // Update now's line (#146) says the run is over.
            if workflow.settings.labels.contains(DashboardUpdate.label) { dashboardChanged(workflow.folder) }
        }

        let folder = Project.standardize(run.folder)
        // On the log (042), a step deeper than the run, as the old trigger fires.
        raise(EventDraft(name: "workflow.completed", at: now(), scope: .project(folder: folder),
                         sentence: "Workflow \(workflow(run.workflowID, in: run.folder)?.name ?? run.workflowID) finished.",
                         details: ["workflow": run.workflowID]
                            .merging(run.agentID.map { ["agent": $0.uuidString,
                                                         "agent_title": agents[$0]?.title ?? "Untitled"] } ?? [:]) { $1 }
                            // What its agent's report said, when it made one (073 FR-004).
                            .merging(run.agentID.flatMap { agents[$0]?.report }
                                .map { ["outcome": $0.outcome.rawValue] } ?? [:]) { $1 },
                         chainDepth: run.depth + 1))
        guard let byID = workflows[folder] else { return }
        for other in byID.values where other.respondsToCompletion(of: run.workflowID)
            && !other.isArchived {
            Task { [weak self] in
                await self?.fire(other, on: .workflowCompleted(id: run.workflowID),
                                 depth: run.depth + 1)
            }
        }
    }

    // MARK: Cooldowns (#103)

    /// Keep this trigger for when the cooldown ends, in place of any kept before it.
    func hold(_ fire: HeldWorkflowFire, for workflow: Workflow) {
        var records = workflowStore.load()
        records.update(folder: workflow.folder, workflowID: workflow.workflowID) { $0.heldFire = fire }
        keepQuietly("workflow history") { try workflowStore.save(records) }
    }

    /// Run each held trigger whose cooldown is over and whose last run has finished,
    /// once. Held for a workflow since put away, turned off or removed, it is let go:
    /// the trigger would not have run it then either.
    func releaseHeldWorkflowFires(now: Date) async {
        var records = workflowStore.load()
        var due: [(Workflow, HeldWorkflowFire)] = []
        var dropped = false
        for state in records.states {
            guard let held = state.heldFire else { continue }
            guard let workflow = workflows[state.folder]?[state.workflowID],
                  !workflow.isArchived, !workflow.isOff else {
                records.update(folder: state.folder, workflowID: state.workflowID) { $0.heldFire = nil }
                dropped = true
                continue
            }
            guard !isRunning(workflow),
                  workflow.cooldownEnds(after: state.lastFiredAt, now: now) == nil else { continue }
            records.update(folder: state.folder, workflowID: state.workflowID) { $0.heldFire = nil }
            due.append((workflow, held))
        }
        guard dropped || !due.isEmpty else { return }
        keepQuietly("workflow history") { try workflowStore.save(records) }
        for (workflow, held) in due {
            await fire(workflow, on: held.trigger, triggeringAgentID: held.triggeringAgentID,
                       depth: held.depth, at: now, causingEvent: held.causingEvent)
        }
    }

    // MARK: What the app asks for

    /// Run now.
    ///
    /// Not a bypass. It ignores the schedule and starts a chain at zero, and it still
    /// obeys every other rule — the run in flight, the ceilings, the archive —
    /// returning the refusal on the summary rather than swallowing it. Somebody is
    /// watching when they tap this, so being told why matters more here than anywhere.
    @discardableResult
    public func runWorkflow(_ request: DaemonAPI.WorkflowRequest) async throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        await fire(workflow, on: .schedule(WorkflowSchedule()), byHand: true)
        return summary(for: workflow)
    }

    /// Turn one on or off (#100).
    ///
    /// Written into the workflow's own file as `enabled: false`, and taken out again
    /// when it is turned on (#125), so the switch travels with the project. Who moved
    /// it stays on this host, for the page's reason and the rule about agents. Unlike
    /// archiving, the last outcome is kept — turning a workflow off and on again should
    /// not forget that it was failing.
    public func setWorkflowEnabled(_ request: DaemonAPI.WorkflowEnableRequest,
                                   byAgent: Bool = false) throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        var records = workflowStore.load()
        let written = try editWorkflowFile(workflow, in: &records) {
            try WorkflowSwitches.setting(enabled: request.enabled, in: $0)
        }
        records.update(folder: request.folder, workflowID: request.workflowID) {
            $0.offBy = request.enabled ? nil : (byAgent ? .agent : .person)
            $0.offDigest = request.enabled ? nil : written.digest
            // A held trigger was a trigger, and none run an off workflow.
            if !request.enabled { $0.heldFire = nil }
        }
        try keep("this workflow's settings") { try workflowStore.save(records) }
        return try rereadAfterWrite(workflow)
    }

    /// Put one away, or bring it back.
    ///
    /// The counterweight to an agent writing a workflow without asking first, and the
    /// reason it can. Not a delete: the file stays in the project, with `archived: true`
    /// in its front matter (#125), where it is still a file somebody can read, edit or
    /// commit — the app simply stops acting on it, and says so on the row rather than
    /// making the workflow disappear.
    public func archiveWorkflow(_ request: DaemonAPI.WorkflowArchiveRequest) throws -> WorkflowSummary {
        guard let workflow = workflow(request.workflowID, in: request.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "There is no workflow called \(request.workflowID) in this project.")
        }
        var records = workflowStore.load()
        try editWorkflowFile(workflow, in: &records) {
            try WorkflowSwitches.setting(archived: request.archived, in: $0)
        }
        records.update(folder: request.folder, workflowID: request.workflowID) {
            // What it last did belonged to the life it had before. Keeping it would
            // leave a restored workflow wearing a refusal from a fortnight ago.
            $0.lastOutcome = nil
            $0.heldFire = nil
        }
        try keep("this workflow's settings") { try workflowStore.save(records) }
        // The rescan tells every window, and every other workflow in the project:
        // putting a waiting one away lets the next in line be approved (#132).
        return try rereadAfterWrite(workflow)
    }

    /// The workflow as its file now says, after the app wrote it.
    ///
    /// Synchronously, and not through the watcher. The watcher is debounced by 250ms and
    /// will fire anyway and find nothing changed; waiting that long to tell the window
    /// what it just asked for is the kind of lag that reads as the app having ignored
    /// you. The rescan also broadcasts to every other window.
    func rereadAfterWrite(_ workflow: Workflow) throws -> WorkflowSummary {
        rescanWorkflows(in: workflow.folder)
        guard let reread = self.workflow(workflow.workflowID, in: workflow.folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchWorkflow,
                               message: "\(workflow.workflowID) went while it was being changed.")
        }
        let summary = summary(for: reread)
        // A change the rescan could not see — the outcome or held trigger let go — is
        // still news to the windows.
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
            if let text = request.cooldown {
                var length: TimeInterval?
                if !text.isEmpty {
                    switch WorkflowCooldown.parse(text) {
                    case .success(let parsed): length = parsed
                    case .failure(let failure):
                        throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable, message: failure.message)
                    }
                }
                if length != existing.cooldown {
                    edited = try FrontMatterEdit.set(WorkflowCooldown.key,
                                                     to: length.map(WorkflowCooldown.fileText), in: edited)
                }
            }
        } catch let refusal as FrontMatterEdit.Refusal {
            // The editor's own sentence, unchanged. It is the one that knows what it
            // found, and nothing was written (FR-025).
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable, message: refusal.message)
        }

        // A save through the app is the person's own change, so it is approved as it is
        // written — but only if what it changed was approved already, and only from a
        // person's connection. Security review S6 kept a phone's edit waiting for the
        // Mac; since #111 a phone may approve as the Mac may, so the phone's save is the
        // person's too. An agent's never is. `rewriteWorkflowFile` carries the approval
        // only when the old bytes were approved.
        var records = workflowStore.load()
        try rewriteWorkflowFile(existing, to: edited, from: original, in: &records,
                                carryApproval: RequestConnection.role.isPerson)
        try keep("this workflow's settings") { try workflowStore.save(records) }

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
            workflowRuns[folder.path + "/" + run.workflowID] = run
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
        keepQuietly("workflow history") { try workflowStore.save(records) }
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
