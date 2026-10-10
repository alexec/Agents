import Foundation
import AgentsKitCore

/// A turn that ended on a blip its runtime says it retries (#513).
///
/// Cursor writes `Error: RetriableError: [unavailable] getaddrinfo ENOTFOUND …` into its
/// reply and usually carries on by itself. When the turn ends on that line instead, the
/// agent stops as a runtime error, never as done, and the app tells it to carry on after
/// each of the policy's waits. Once they are used up it stays stopped, and says so.
extension DaemonCore {
    func carryOnPastRetriedError(agentID: UUID) async {
        guard let agent = agents[agentID] else { return }
        let runtimeName = RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? "The runtime"
        let attempt = retriedErrorAttempts[agentID, default: 0]
        guard let delay = retriedErrorPolicy.delay(forAttempt: attempt) else {
            retriedErrorAttempts[agentID] = nil
            await record(.runtimeNote(
                "\(runtimeName) could not get past a network error after \(attempt) tries, so the turn stops here. "
                + "Send a prompt to try again."), for: agentID)
            return
        }
        retriedErrorAttempts[agentID] = attempt + 1
        await record(.runtimeNote(
            "\(runtimeName) stopped on a network error. Trying again in \(Int(delay)) seconds."), for: agentID)
        let stopsBefore = stops[agentID, default: 0]
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.carryOnAfterRetriedError(agentID: agentID, stopsBefore: stopsBefore)
        }
    }

    /// Unless the agent has moved on since: stopped, archived, given another prompt, or
    /// already working.
    private func carryOnAfterRetriedError(agentID: UUID, stopsBefore: Int) async {
        guard stops[agentID, default: 0] == stopsBefore, var agent = agents[agentID],
              agent.state == .stopped, agent.endedReason == .runtimeError,
              agent.queuedPrompts.isEmpty, !turnIsRunning(agentID) else { return }
        agent.queuedPrompts.append(QueuedPrompt(text: Self.carryOn, from: .app))
        changed(agent)
        do {
            try await sendNextQueued(to: agentID)
        } catch {
            await record(.runtimeNote("Could not try again: \(reason(error))"), for: agentID)
        }
    }

    /// For tests: shorter waits between tries.
    func useRetriedErrorPolicy(_ policy: RetriedErrorPolicy) {
        retriedErrorPolicy = policy
    }
}
