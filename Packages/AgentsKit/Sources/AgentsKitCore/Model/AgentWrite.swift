import Foundation

/// A change to one agent's record that a person asked for, drawn before its host
/// answers (#4786). The client's copy changes at once; the change stays pending until
/// the host's record agrees, and goes back when the call fails.
///
/// What each one does to the record is only what the host will do too: the host's
/// record is still the one that is true, and replaces this one when it comes.
public enum AgentWrite: Sendable, Hashable {
    case archive
    case unarchive
    case stop
    /// The person's title; empty gives the runtime's title back.
    case rename(String)
    case labels(add: [String], remove: [String])
    case mute(Bool)
    /// A queued prompt sent into the running turn, by its id.
    case sendNow(UUID)
    /// A queued session started at once (#5156): drawn as starting.
    case startNow
    /// Move to a worktree or back to the folder (053), or with nil take back the move that
    /// waits (#4814). Drawn as the move that waits: the host makes it at once between
    /// turns, and its record then says where the agent is.
    case move(MoveTarget?)

    /// The verb for the line that says what failed: "Could not archive".
    public var verb: String {
        switch self {
        case .archive: return "archive"
        case .unarchive: return "unarchive"
        case .stop: return "stop"
        case .rename: return "rename"
        case .labels: return "change the labels"
        case .mute(let muted): return muted ? "mute" : "unmute"
        case .sendNow: return "send now"
        case .startNow: return "start it now"
        case .move(let target): return target == nil ? "cancel the move" : "move"
        }
    }

    /// The one line a client shows when the call failed: what failed, then why.
    public func failure(_ reason: String) -> String { Self.failure(verb, reason) }

    /// "Could not <verb> — <why>", for any change drawn before its answer (#4814).
    public static func failure(_ verb: String, _ reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = "Could not \(verb)"
        guard !reason.isEmpty else { return head + "." }
        return head + " — " + reason.prefix(1).lowercased() + reason.dropFirst()
    }

    /// The record as the person expects to see it once the host has done this.
    public func applied(to agent: Agent, at now: Date = Date()) -> Agent {
        var agent = agent
        switch self {
        case .archive:
            agent.state = .archived
            agent.archivedAt = agent.archivedAt ?? now
            agent.archivedReason = .byUser
            agent.archiveRequest = nil
        case .unarchive:
            guard agent.state == .archived else { break }
            // As the host does: finished for a turn that ended itself, stopped otherwise.
            agent.state = agent.endedReason == .endTurn ? .finished : .stopped
            if agent.endedReason == nil { agent.endedReason = .unrecognised }
            agent.archivedAt = nil
            agent.archivedReason = nil
        case .stop:
            guard Self.stops(agent.state) else { break }
            agent.state = .stopped
            agent.endedReason = .cancelled
        case .rename(let title):
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                if agent.titleIsPersons { agent.title = agent.runtimeTitle }
                agent.titleIsPersons = false
                agent.runtimeTitle = nil
            } else {
                if !agent.titleIsPersons { agent.runtimeTitle = agent.title }
                agent.title = title
                agent.titleIsPersons = true
            }
        case .labels(let add, let remove):
            let gone = Set(remove.map(SessionLabelPolicy.key))
            agent.labels.removeAll { gone.contains($0.normalizedValue) }
            for value in add where !agent.labels.contains(where: { $0.normalizedValue == SessionLabelPolicy.key(value) }) {
                agent.labels.append(SessionLabel(value: value, owner: .person, addedAt: now))
            }
        case .mute(let muted):
            agent.isMuted = muted
        case .sendNow(let promptID):
            agent.queuedPrompts.removeAll { $0.id == promptID }
        case .startNow:
            guard agent.state == .queued else { break }
            agent.state = .starting
        case .move(let target):
            agent.pendingMove = target.map { PendingMove(target: $0, askedBy: .person, askedAt: now) }
        }
        return agent
    }

    /// The states Stop ends: a turn in flight, or a start still in line.
    static func stops(_ state: AgentState) -> Bool { state.hasTurnInFlight || state == .queued }

    /// Whether the host's record already says this happened, so the pending change can go.
    public func isSettled(by agent: Agent) -> Bool {
        switch self {
        case .archive: return agent.state == .archived
        case .unarchive: return agent.state != .archived
        case .stop: return !Self.stops(agent.state)
        case .rename(let title):
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? !agent.titleIsPersons : agent.titleIsPersons && agent.title == title
        case .labels(let add, let remove):
            let held = Set(agent.labels.map(\.normalizedValue))
            return add.allSatisfy { held.contains(SessionLabelPolicy.key($0)) }
                && remove.allSatisfy { !held.contains(SessionLabelPolicy.key($0)) }
        case .mute(let muted): return agent.isMuted == muted
        case .sendNow(let promptID): return !agent.queuedPrompts.contains { $0.id == promptID }
        case .startNow: return agent.state != .queued
        case .move(let target):
            // Waiting for the turn to end, or taken back. A move made at once is settled by
            // the host's answer instead (`settleWrite(_:on:failed:done:)`).
            return agent.pendingMove?.target == target
        }
    }
}
