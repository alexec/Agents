import Foundation

/// What an agent left running in the background (057): the shells and subagents the
/// runtime announces, kept on `Agent.background`, and the one thing a person can do to
/// them from here, which is stop a task.
extension DaemonCore {
    /// One of the five updates arrived. The list is always current; the chat gets a
    /// line when something starts and when it ends, as it stood then.
    func noteBackground(_ update: BackgroundUpdate, agentID: UUID) async {
        guard var agent = agents[agentID] else { return }
        let before = agent.background.first { $0.id == update.itemID }
        let (items, announce) = BackgroundItem.applying(update, to: agent.background)
        guard items != agent.background else { return }
        agent.background = items
        changed(agent)
        guard let announce else { return }
        // A task stopped from here already has its line: the runtime's own notice,
        // "Task stopped by user", which arrives beside the ending. Two lines for one
        // click is one too many.
        if announce.state == .stopped, before?.isStopping == true { return }
        await record(.background(announce), for: agentID, subagentID: announce.parentID)
    }

    /// `agents/stopBackground`. True when the runtime stopped it.
    ///
    /// Asked of the runtime only if it said Stop works on this one, and only while it
    /// runs. The row shows the stop under way until the runtime answers, and goes back
    /// to running if the runtime refuses, so a failed stop is never shown as a done one.
    public func stopBackground(_ request: DaemonAPI.StopBackgroundRequest) async throws -> Bool {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard let item = agent.background.first(where: { $0.id == request.itemID }) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Nothing by that name is running.")
        }
        guard item.isRunning else { return false }
        guard item.canStop, let session = live[request.agentID] else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "\(item.name) can't be stopped on its own. Stop the agent to stop it.")
        }
        setStopping(request.itemID, of: request.agentID, true)
        do {
            let stopped = try await session.stopBackgroundTask(request.itemID)
            // Stopped: the runtime's own ending has cleared the mark, or is about to.
            // Not stopped: it had already gone, and its ending is on its way.
            if !stopped { setStopping(request.itemID, of: request.agentID, false) }
            return stopped
        } catch {
            setStopping(request.itemID, of: request.agentID, false)
            throw error
        }
    }

    private func setStopping(_ itemID: String, of agentID: UUID, _ stopping: Bool) {
        guard var agent = agents[agentID],
              let index = agent.background.firstIndex(where: { $0.id == itemID }),
              agent.background[index].isRunning || !stopping,
              agent.background[index].isStopping != stopping else { return }
        agent.background[index].isStopping = stopping
        changed(agent)
    }

    /// The runtime is gone, and whatever it was running went with it. The app lets a
    /// runtime go when its turn ends, so this is how a shell left running ends (Alex,
    /// 2026-09-26: background work ends with the turn). Said on the list at once, and
    /// once in the chat, so nobody takes a server for still being up.
    func endBackground(of agentID: UUID) {
        guard var agent = agents[agentID], agent.background.contains(where: \.isRunning) else { return }
        let ending = Set(agent.background.filter(\.isRunning).map(\.id))
        agent.background = BackgroundItem.disconnecting(agent.background)
        changed(agent)
        let ended = agent.background.filter { ending.contains($0.id) }
        Task {
            for item in ended { await record(.background(item), for: agentID, subagentID: item.parentID) }
        }
    }
}
