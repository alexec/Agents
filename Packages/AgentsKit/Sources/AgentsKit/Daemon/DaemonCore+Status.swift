import AgentsKitCore
import Foundation

/// How busy this daemon is, and going when asked (037).
///
/// A server's daemon runs with `--serve` and never leaves for being idle, so the window
/// needs a way to ask it to: to swap in a new version between turns, and to remove the
/// server.
extension DaemonCore {
    /// Mid-turn means starting, running or waiting on the person. The last counts:
    /// swapping the binary under a pending permission would drop the question.
    func status() -> DaemonAPI.DaemonStatus {
        let holding = agents.values.filter { $0.state.holdsRuntime }
        let inFlight = holding.filter {
            switch $0.state {
            case .starting, .running, .waitingOnUser: true
            default: false
            }
        }
        return DaemonAPI.DaemonStatus(turnsInFlight: inFlight.count, agentsLive: holding.count)
    }

    /// Without `stopAgents`, a turn in flight refuses: the window waits and asks again.
    /// With it, every agent holding a runtime is stopped the way Stop stops it, which is
    /// what the Remove dialog has just told the person will happen.
    func quit(_ request: DaemonAPI.QuitRequest) async throws {
        if request.stopAgents {
            for agent in agents.values where agent.state.holdsRuntime {
                try? await stop(agent.id)
            }
        } else if status().turnsInFlight > 0 {
            throw JSONRPCError(code: DaemonAPI.Failure.busy,
                               message: "An agent here is mid-turn. Ask again when it has finished.")
        }
        DaemonLog.shared.write("asked to quit\(request.stopAgents ? ", stopping agents" : "")")
        quitRequested = true
    }
}
