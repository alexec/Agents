import Foundation
import AgentsKitCore

/// The person's first steps in Agents (#984), worked out from what the host already keeps:
/// its agents, its paired devices, its workflows, the Time page's days and records, the
/// workspaces the control plane lists, and the calls a phone or a browser makes. Nothing
/// new is tracked; only what was earned, and when, is written, in `achievements.json`.
///
/// The first look back-fills what the records say was earned before this shipped. A
/// question answered from away and a cloud host started have no record to look back on,
/// so they start fresh.
extension DaemonCore {
    /// `milestones/state`.
    public func milestones() -> Milestones {
        if let loadedMilestones { return loadedMilestones }
        let read = StoreFile.load(Milestones.self, at: locations.achievements, empty: Milestones(),
                                  meaning: "the milestones start again from nothing")
        loadedMilestones = read
        return read
    }

    /// Earn these, where not earned yet: written, and told to every client.
    func earn(_ found: [(Milestone, Date)]) {
        var milestones = milestones()
        let new = found.filter { milestones.earn($0.0, at: $0.1) }
        guard !new.isEmpty else { return }
        loadedMilestones = milestones
        keepQuietly("the milestones") {
            try StoreFile.write(try StoreCoding.encoder.encode(milestones), to: locations.achievements)
        }
        broadcast(DaemonAPI.Notification.milestonesChanged, milestones)
    }

    func earn(_ milestone: Milestone) {
        guard !milestones().has(milestone) else { return }
        earn([(milestone, now())])
    }

    /// Look at the records for what they say was earned. Cheap once earned: each kind of
    /// record is only read while its milestone is still open.
    func checkMilestones() {
        let held = milestones()
        let want: (Milestone) -> Bool = { !held.has($0) }
        guard [.firstAgent, .firstPairing, .firstWorkflow, .firstLandedPR, .fiveAtOnce].contains(where: want) else {
            return
        }
        let at = now()
        let facts = Milestones.Facts(
            agents: want(.firstAgent) ? Array(agents.live.values) + Array(agents.archived.values) : [],
            devices: want(.firstPairing) ? pairedDevices : [],
            hasWorkflow: want(.firstWorkflow) && workflows.values.contains { $0.values.contains { $0.runs(on: MachineID.current) } },
            time: want(.firstLandedPR) || want(.fiveAtOnce) ? timeLedger.history(at: at) : TimeHistory())
        var found = held
        let new = found.earn(from: facts, now: at)
        earn(new.compactMap { milestone in found.at(milestone).map { (milestone, $0) } })
    }

    /// What a call says, once it has been answered: a phone, an iPad or a browser is
    /// paired when one calls at all, and answering a question from one is answering from
    /// away from the Mac.
    func noteMilestones(method: String, role: ConnectionRole) {
        guard role == .device else { return }
        earn(.firstPairing)
        if method == DaemonAPI.Method.elicitationsAnswer || method == DaemonAPI.Method.permissionsAnswer {
            earn(.firstRemoteAnswer)
        }
    }

    /// Whether any workspace a cloud provider made is running, as the control plane
    /// lists them. Asked with the hourly count of merged pull requests, so a workspace
    /// started from a window, which the host is not told of, is found within the hour.
    func checkCloudHosts() async {
        guard !milestones().has(.firstCloudHost), let askControl else { return }
        let call = DaemonAPI.HostWorkspaceCall(agent: "Agents Host", method: DaemonAPI.Method.workspacesForAgent,
                                               params: [:])
        guard let params = try? JSONValue.encoding(call),
              let listed = try? await askControl(DaemonAPI.Method.hostWorkspaces, params)
                .decode(DaemonAPI.AgentWorkspaces.self) else { return }
        if Self.anyRunning(listed) { earn(.firstCloudHost) }
    }

    static func anyRunning(_ listed: DaemonAPI.AgentWorkspaces) -> Bool {
        listed.providers.contains { $0.workspaces.contains { $0.state == "running" || $0.hostState == "online" } }
    }
}
