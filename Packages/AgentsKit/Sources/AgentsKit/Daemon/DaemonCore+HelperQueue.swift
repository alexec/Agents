import Foundation
import AgentsKitCore

/// Helpers queued past a project's limits, and started when a place frees (#362).
///
/// A `start_agent` that would break the running or not-archived limit is written down
/// as a `queued` agent: its words, runtime and worktree kept on the record, nothing
/// spawned, nothing spent. Queued agents go behind working and waiting ones — a place
/// is free only when `HelperLimit.isRunning` says fewer than the limit hold one, and a
/// not-archived place is free too — and start first in, first out within the project.
/// How many may wait is the person's third limit, beside the other two; past it a start
/// is refused as before.
///
/// The queue is the records themselves, so it outlives a restart: the daemon looks at
/// every project's queue once it has recovered, and whenever a helper stops holding a
/// place after that.
extension DaemonCore {
    /// How many may wait in this project's queue.
    func queueLimit(in folder: URL) -> Int {
        (configuredHelperLimits(in: folder) ?? HelperLimits()).effectiveQueued
    }

    /// Write a start down as queued, or refuse it when the queue is full too. Every
    /// check before the first `await`, as `startHelper`'s are.
    func queueHelper(_ request: DaemonAPI.StartHelperRequest, prompt: String, caller: Agent,
                     depth: Int?, full: String?) async throws -> (note: String, agentID: UUID) {
        let folder = caller.projectFolder
        let queue = HelperLimit.queue(in: folder, agents: agents.inProject(folder))
        let waiting = queue.count + reservedQueue[folder, default: 0]
        let limit = queueLimit(in: folder)
        if waiting >= limit {
            let names = queue.isEmpty ? "" : " — " + queue.map { "\u{201C}\($0.title ?? "Untitled")\u{201D}" }
                .joined(separator: ", ")
            let behind = full.map { $0 + " And its" } ?? "This project's"
            throw JSONRPCError(
                code: DaemonAPI.Failure.notYours,
                message: "Nothing was started: \(behind) queue is full too: \(waiting) of \(limit) "
                    + "agents queued\(names). Stop one of yours that is queued with \(AppTool.stopAgent) "
                    + "if it is no longer wanted, or wait for the queue to move. "
                    + "The person sets these limits in Project Settings.")
        }
        reservedQueue[folder, default: 0] += 1
        defer { reservedQueue[folder, default: 1] -= 1 }

        // What can be checked without making a runtime is checked now, so a start that
        // could never run is refused here rather than failing when its turn comes.
        let runtimeID = request.runtime ?? RuntimeCatalog.defaultRuntime.id
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was started: there is no runtime called \"\(runtimeID)\" — "
                                   + "this version knows " + RuntimeCatalog.builtIn.map(\.id).joined(separator: ", ") + ".")
        }
        if let refusal = unavailableRuntimeRefusal(runtime) {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Nothing was started: \(refusal).")
        }
        let labels: [SessionLabel]
        let worktree: WorktreeChoice?
        do {
            labels = try SessionLabelPolicy.change(
                current: [], add: request.labels, actor: .agent,
                projectLabels: SessionLabelPolicy.vocabulary(in: folder, agents: agents.inProject(folder)))
            worktree = try await helperWorktree(request.worktree, in: folder)
        } catch let error as JSONRPCError {
            throw JSONRPCError(code: error.code, message: "Nothing was started: \(error.message)", data: error.data)
        } catch {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was started: \(error.localizedDescription)")
        }

        var agent = Agent(runtimeID: runtimeID, cwd: folder, title: Agent.fallbackTitle(from: prompt),
                          state: .queued, queuedPrompts: [QueuedPrompt(text: prompt)],
                          startedByAgent: caller.id, chainDepth: depth)
        agent.labels = labels
        agent.madeInRoot = rootID
        agent.queuedStart = QueuedStart(
            runtimeID: request.runtime,
            permissionMode: request.permissionMode ?? inheritedMode(from: caller, runtime: request.runtime),
            model: request.model, worktree: worktree, labels: request.labels)
        do {
            try await store.save(agent)
        } catch {
            throw couldNotSave(error, keeping: "the queued agent")
        }
        changed(agent)
        await record(.runtimeNote("Queued by \(starterName(caller.id)). It starts by itself when this "
                                  + "project has a place free."), for: agent.id)

        let title = agent.title ?? "Untitled"
        let position = HelperLimit.queuePosition(of: agent, among: agents.inProject(folder)) ?? waiting + 1
        var note = "Queued \u{201C}\(title)\u{201D} (id \(agent.id.uuidString)), \(HelperLimit.ordinal(position)) "
            + "in this project's queue: "
        note += full.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) " } ?? "Others are queued ahead of it. "
        note += "It starts by itself, oldest first, once a running place and a not-archived place are both "
            + "free. Wait for it with \(AppTool.waitForEvent) as for any agent, or take it off the queue with "
            + "\(AppTool.stopAgent). This project now has \(helperPlaces(in: folder))."
        checkQueueSoon(in: folder)
        return (note, agent.id)
    }

    /// Look at a project's queue once the call in hand is done: it may have freed a place.
    func checkQueueSoon(in folder: URL) {
        let folder = Project.standardize(folder)
        guard queueChecks.insert(folder).inserted else { return }
        Task { self.startFromQueue(in: folder) }
    }

    /// Every project with a queue, after a restart: queued agents are on disk and are
    /// not brought back as running, so nothing else would look.
    func checkEveryQueue() {
        let folders = Set(agents.values.filter { $0.state == .queued }.map(\.projectFolder))
        for folder in folders { checkQueueSoon(in: folder) }
    }

    /// Start the oldest queued agents for as many places as are free. Each place is
    /// taken before anything is awaited, as `startHelper` takes one.
    func startFromQueue(in folder: URL) {
        queueChecks.remove(folder)
        while let next = nextFromQueue(in: folder) {
            startingFromQueue.insert(next.id)
            reservedStarts[folder, default: 0] += 1
            Task { await self.startQueued(next.id, in: folder) }
        }
    }

    /// The oldest queued agent not already starting, if both its places are free.
    private func nextFromQueue(in folder: URL) -> Agent? {
        let members = agents.inProject(folder)
        guard let next = HelperLimit.queue(in: folder, agents: members)
                .first(where: { !startingFromQueue.contains($0.id) }) else { return nil }
        let limits = helperLimits(in: folder)
        let reserved = reservedStarts[folder, default: 0]
        let comingBack = resuming.union(interrupted.keys)
        guard HelperLimit.running(in: folder, agents: members, reserved: reserved,
                                  comingBack: comingBack) < limits.running,
              HelperLimit.placesInUse(in: folder, agents: members, reserved: reserved) < limits.notArchived
        else { return nil }
        return next
    }

    /// Make the queued agent, as `startHelper` would have, under its own id. One that
    /// cannot be made now is stopped, saying why, and the next one is looked at.
    private func startQueued(_ id: UUID, in folder: URL) async {
        defer {
            startingFromQueue.remove(id)
            reservedStarts[folder, default: 1] -= 1
            checkQueueSoon(in: folder)
        }
        guard let agent = agents[id], agent.state == .queued, let starter = agent.startedByAgent else { return }
        let saved = agent.queuedStart ?? QueuedStart(runtimeID: agent.runtimeID)
        let prompt = agent.queuedPrompts.first?.text ?? agent.title ?? ""
        let settings = WorkflowSettings(permissionMode: saved.permissionMode, runtimeID: saved.runtimeID,
                                        model: saved.model)
        do {
            var start = try await startRequest(settings: settings, folder: folder, prompt: prompt,
                                               managesAgents: false, checksDefault: true)
            start.worktree = saved.worktree
            start.labels = saved.labels
            _ = try await self.start(start, startedBy: starter, chainDepth: agent.chainDepth, queued: id)
        } catch {
            guard agents[id]?.state == .queued else { return }
            let why = (error as? SettingRefused)?.detail ?? (error as? JSONRPCError)?.message
                ?? error.localizedDescription
            await record(.runtimeNote("It could not start from the queue: \(why)"), for: id)
            await move(id, on: .couldNotStartFromQueue)
        }
    }
}
