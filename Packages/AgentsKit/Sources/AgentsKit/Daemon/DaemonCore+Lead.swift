import Foundation

/// The one agent per project whose job is the project.
///
/// It is created when the project is first listed, which is a file write and nothing
/// more: no process, no tokens. Its runtime starts the first time somebody prompts it,
/// through the same path that picks up any stopped agent.
extension DaemonCore {
    /// The lead of a folder, if there is one.
    func lead(in folder: URL) -> Agent? {
        let standardized = Project.standardize(folder)
        return agents.values.first {
            $0.role == .lead && Project.standardize($0.cwd) == standardized
        }
    }

    /// Make sure a project has a lead, making one if it has none.
    ///
    /// Called from `projects/list`, because that is the one call every window makes and
    /// the one place a project is known to exist. Writing the record costs a file
    /// write; nothing is started and nothing is spent until it is prompted.
    func ensureLead(for folder: URL) async {
        let standardized = Project.standardize(folder)
        guard lead(in: standardized) == nil else { return }
        guard let runtimeID = defaultRuntimeIDForLead() else { return }

        let agent = Agent(runtimeID: runtimeID,
                          cwd: standardized,
                          title: "Project lead",
                          // Never started, so it reads as an agent that has stopped
                          // cleanly. `endedReason` is what keeps that consistent.
                          state: .stopped,
                          runtimeSessionID: nil,
                          endedReason: .endTurn,
                          role: .lead)
        agents[agent.id] = agent
        try? await store.save(agent)
        broadcast(DaemonAPI.Notification.agentChanged, agent)
    }

    /// Which runtime a new lead is given.
    ///
    /// Whatever is installed and signed in, preferring the one the user's most recent
    /// agent used, because that is the one they have chosen in every other sense. The
    /// user can change it from the lead's own conversation like any agent's.
    private func defaultRuntimeIDForLead() -> String? {
        let recent = agents.values
            .filter { $0.role == .worker }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .first?.runtimeID
        let available = runtimeStatuses().filter { $0.availability.isAvailable }.map(\.runtime.id)
        if let recent, available.contains(recent) { return recent }
        return available.first ?? RuntimeCatalog.builtIn.first?.id
    }

    /// A project is being archived, so its lead goes with it.
    ///
    /// The workers are left alone — their own states are what unarchiving restores —
    /// but a lead cannot be archived on its own, so this is the only way it moves.
    func archiveLead(in folder: URL) async {
        guard var agent = lead(in: folder), agent.state != .archived else { return }
        agent.state = .archived
        agent.archivedReason = .byUser
        agent.lastActivityAt = Date()
        changed(agent)
    }

    /// The project is back, so its lead is too, with the conversation it had.
    func unarchiveLead(in folder: URL) async {
        guard var agent = lead(in: folder), agent.state == .archived else { return }
        agent.state = agent.endedReason == .endTurn ? .finished : .stopped
        agent.archivedReason = nil
        agent.lastActivityAt = Date()
        changed(agent)
    }
}

/// The four rules that keep a lead inside its own project.
///
/// Pure functions over records, so they are exhaustible by a test and cannot be
/// accidentally skipped by a caller that forgot. This is the part of the feature where
/// a mistake reaches somebody's work rather than their window.
public enum ProjectToolGuards {
    /// Why a lead was told no. The lead reads these, so they are sentences.
    public enum Refusal: Hashable, Sendable {
        case notALead
        case otherProject(projectName: String)
        case itself
        case alreadySettled
        case archived

        public func message(projectName: String = "this project") -> String {
            switch self {
            case .notALead:
                return "Only a project lead can do that."
            case .otherProject(let name):
                return "That agent is in another project. You can only work with agents in \(name)."
            case .itself:
                return "You cannot stop yourself. Ask the user to stop you."
            case .alreadySettled:
                return "That agent already finished. Nothing to stop."
            case .archived:
                return "That agent is archived. Unarchive it before giving it work."
            }
        }
    }

    /// Only a lead is offered these tools at all.
    public static func check(caller: Agent) -> Refusal? {
        caller.role == .lead ? nil : .notALead
    }

    /// A named agent must be in the caller's own project.
    ///
    /// Matched on the folder, exactly, the same way an agent is matched to a project
    /// everywhere else. There is no tool that names a project, so this is the only
    /// thing that decides reach.
    public static func check(caller: Agent, target: Agent, projectName: String) -> Refusal? {
        if let refusal = check(caller: caller) { return refusal }
        guard Project.standardize(target.cwd) == Project.standardize(caller.cwd) else {
            return .otherProject(projectName: projectName)
        }
        return nil
    }

    /// Stopping. A lead may not stop itself, and stopping something already finished is
    /// nothing to do rather than a failure.
    public static func checkStop(caller: Agent, target: Agent, projectName: String) -> Refusal? {
        if let refusal = check(caller: caller, target: target, projectName: projectName) {
            return refusal
        }
        if target.id == caller.id { return .itself }
        if !target.state.holdsRuntime { return .alreadySettled }
        return nil
    }

    /// Prompting. An archived agent is not given work.
    public static func checkPrompt(caller: Agent, target: Agent, projectName: String) -> Refusal? {
        if let refusal = check(caller: caller, target: target, projectName: projectName) {
            return refusal
        }
        if target.state == .archived { return .archived }
        return nil
    }

    /// What a tool creates, always. There is no argument for this and no path to a
    /// second lead: a lead is made with its project and nowhere else.
    public static let roleForStartedAgents: AgentRole = .worker
}
