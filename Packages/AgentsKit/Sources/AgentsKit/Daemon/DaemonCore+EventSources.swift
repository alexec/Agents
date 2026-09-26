import Foundation
import AgentsKitCore

/// Where events come from besides agents, workflows and pull requests (042 R9–R11).
extension DaemonCore {
    // MARK: branch.moved (R9)

    /// Watch a project's `.git` for branch tips moving. Called wherever a project's
    /// workflows are adopted, which is everywhere a project becomes live.
    func watchBranches(in folder: URL) {
        let folder = Project.standardize(folder)
        guard branchWatchers[folder] == nil, Self.isDirectory(folder.appending(path: ".git")) else { return }
        branchWatchers[folder] = FolderWatch(root: folder) { [weak self] changed in
            guard changed.contains(where: Self.isBranchPath) else { return }
            Task { await self?.scheduleBranchCheck(in: folder) }
        }
        // Seed what the tips are now, so the first move after this is a move.
        scheduleBranchCheck(in: folder, after: .zero)
    }

    func stopWatchingAllBranches() {
        for (_, watch) in branchWatchers { watch.stop() }
        branchWatchers.removeAll()
    }

    /// Whether a changed path is a branch tip or what a worktree has checked out.
    static func isBranchPath(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/.git/refs/heads") || path.hasSuffix("/.git/packed-refs")
            || path.hasSuffix("/.git/HEAD") || (path.contains("/.git/worktrees/") && path.hasSuffix("/HEAD"))
    }

    /// Wait for git to finish writing — a rebase writes many refs — then look once.
    func scheduleBranchCheck(in folder: URL, after delay: Duration = .seconds(1)) {
        branchChecks[folder]?.cancel()
        branchChecks[folder] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.checkBranches(in: folder)
        }
    }

    /// The branches worth saying moved: the project's default branch, and each branch
    /// an agent's worktree in it is on.
    func watchedBranches(in folder: URL) async -> Set<String> {
        var branches = Set(agents.values.compactMap { agent -> String? in
            guard agent.state != .archived, agent.projectFolder == folder else { return nil }
            return agent.worktree?.branch
        })
        branches.insert(await defaultBranch(of: folder))
        return branches
    }

    /// `origin/HEAD`'s branch when there is one, otherwise `main`, otherwise `master`.
    private func defaultBranch(of folder: URL) async -> String {
        if let git = try? GitProcess(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: folder),
           let outcome = try? await git.run(), outcome.succeeded {
            let name = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = name.firstIndex(of: "/") { return String(name[name.index(after: slash)...]) }
        }
        let tips = await branchTips(in: folder)
        return tips["main"] != nil || tips["master"] == nil ? "main" : "master"
    }

    /// Every local branch and the commit it points at.
    func branchTips(in folder: URL) async -> [String: String] {
        guard let git = try? GitProcess(["for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads"],
                                        in: folder),
              let outcome = try? await git.run(), outcome.succeeded else { return [:] }
        var tips: [String: String] = [:]
        for line in outcome.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { tips[String(parts[0])] = String(parts[1]) }
        }
        return tips
    }

    /// Compare the watched branches' tips with those last seen, and raise one
    /// `branch.moved` for each that changed. The first look at a project only seeds
    /// them; a tip that moved while the daemon was down is raised when noticed.
    func checkBranches(in folder: URL) async {
        loadEventsIfNeeded()
        let tips = await branchTips(in: folder)
        let watched = await watchedBranches(in: folder)
        let key = folder.path
        let before = eventState.branchTips[key]
        var now: [String: String] = [:]
        for branch in watched { if let tip = tips[branch] { now[branch] = tip } }
        eventState.branchTips[key] = now
        eventStore.saveState(eventState)
        guard let before else { return }
        for (branch, tip) in now.sorted(by: { $0.key < $1.key }) {
            guard let old = before[branch], old != tip else { continue }
            raise(EventDraft(name: "branch.moved", at: self.now(), scope: .project(folder: folder),
                             sentence: "\(branch) moved to \(tip.prefix(7)).",
                             details: ["branch": branch, "from": String(old.prefix(12)), "to": String(tip.prefix(12))]))
        }
    }

    // MARK: mac.* and person.* (R10)

    /// Start hearing the Mac. The real watch in the daemon; a fake one in a test.
    public func startWatchingMachine(_ watch: any MachineWatch = IOKitMachineWatch()) {
        machineWatch?.stop()
        machineWatch = watch
        // One stream, read by one task, so the changes land in the order they happened:
        // a Task each would let a wake overtake the sleep before it.
        let (changes, continuation) = AsyncStream.makeStream(of: MachineChange.self)
        watch.start { change in continuation.yield(change) }
        Task { [weak self] in
            for await change in changes { await self?.machineChanged(change) }
        }
    }

    /// One change, as its event, for every project to hear (US5-AS3).
    func machineChanged(_ change: MachineChange) {
        let draft: EventDraft
        switch change {
        case .sleep:
            draft = EventDraft(name: "mac.sleep", at: now(), scope: .mac, sentence: "This Mac went to sleep.")
        case .wake:
            draft = EventDraft(name: "mac.wake", at: now(), scope: .mac, sentence: "This Mac woke up.")
        case .away(let why):
            draft = EventDraft(name: "person.away", at: now(), scope: .mac,
                               sentence: why == "locked" ? "You locked the screen." : "You stepped away.",
                               details: ["why": why])
        case .back(let why):
            draft = EventDraft(name: "person.back", at: now(), scope: .mac,
                               sentence: why == "locked" ? "You unlocked the screen." : "You came back.",
                               details: ["why": why])
        }
        raise(draft)
    }

    // MARK: server.* (037)

    /// A server gone or back, as the window saw it: the window holds the servers'
    /// connections, so it says, and the event goes through the one funnel like any other.
    /// A phone has no connection to a server and cannot say.
    @discardableResult
    func raiseServerChange(_ change: DaemonAPI.ServerReachabilityChange, from surface: Surface? = nil) throws -> Event {
        let server = change.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface?.deviceID == nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.eventRefused, message: "Only the Mac's window says how its servers are.")
        }
        guard !server.isEmpty else {
            throw JSONRPCError(code: DaemonAPI.Failure.eventRefused, message: "A server change needs the server's name.")
        }
        return raise(EventDraft(name: change.online ? "server.online" : "server.offline", at: now(), scope: .mac,
                                sentence: change.online ? "\(server) came back." : "\(server) went offline.",
                                details: ["server": server]))
    }

    // MARK: cost.limit_reached (R11)

    /// A spending limit was reached, said once a day for each limit (and each agent's
    /// own): the day's in the Mac's scope, an agent's in its project's.
    func raiseCostLimit(_ limit: String, agent: Agent?) {
        loadEventsIfNeeded()
        let day = Self.dayKey(now())
        let key = agent.map { "agent:\($0.id.uuidString)" } ?? limit
        guard !(eventState.costCrossings[day] ?? []).contains(key) else { return }
        // Only today's are worth keeping.
        eventState.costCrossings = [day: (eventState.costCrossings[day] ?? []) + [key]]
        eventStore.saveState(eventState)
        if let agent {
            raise(EventDraft(name: "cost.limit_reached", at: now(), scope: .project(folder: agent.projectFolder),
                             sentence: "\(LeaseWords.agentName(agent.title)) reached its spending limit.",
                             details: ["limit": limit].merging(agentDetails(agent)) { $1 }))
        } else {
            raise(EventDraft(name: "cost.limit_reached", at: now(), scope: .mac,
                             sentence: "The day's spending limit was reached.", details: ["limit": limit]))
        }
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: lease.* (036)

    /// A lease given or given back, on the Mac's log.
    func raiseLeaseEvent(_ event: LeaseEvent) {
        switch event {
        case .granted(let lease, _, _):
            raise(EventDraft(name: "lease.granted", at: now(), scope: .mac,
                             sentence: "\(holderName(lease.holder)) was given \(lease.displayName).",
                             details: ["resource": lease.resource.key, "agent": lease.holder.uuidString,
                                       "agent_title": agents[lease.holder]?.title ?? "Untitled"]))
        case .released(let lease, let ending):
            let how: String
            switch ending {
            case .expired: how = "expired"
            case .endedByPerson, .holderStopped, .holderArchived, .couldNotStart: how = "ended"
            case .released: how = "released"
            }
            raise(EventDraft(name: "lease.released", at: now(), scope: .mac,
                             sentence: "\(lease.displayName) was \(how == "expired" ? "let go: its lease ran out" : how == "ended" ? "taken back" : "given back").",
                             details: ["resource": lease.resource.key, "how": how]))
        default:
            break
        }
    }
}
