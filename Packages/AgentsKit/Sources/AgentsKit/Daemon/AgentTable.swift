import Foundation
import AgentsKitCore

/// Every agent the daemon holds, with what each change keeps current (#164).
///
/// It used to be one dictionary, and every agent change paid for all of it: the project
/// summary grouped every agent there had ever been, wakefulness and attention walked
/// them all, and nine in ten were archived. At 5,000 agents one label change cost 15 ms
/// against 1.15 ms at ten, on the one actor that owns them.
///
/// So the live agents are held apart from the archived ones, and what a change has to
/// know is kept as it happens rather than counted again:
/// - `live`: what the per-change scans walk. Archived agents never enter it.
/// - `archived`: slim, as `archive.json` has them, read a project and a page at a time.
/// - each folder's members and its `ProjectTally`, which is its summary's numbers;
/// - how many agents are in flight, and which have a wait on events.
///
/// Reading and writing by id is the dictionary's, so the rest of the daemon is unchanged:
/// `agents[id] = agent` files it in the right half and moves every count with it.
struct AgentTable {
    private(set) var live: [UUID: Agent] = [:]
    private(set) var archived: [UUID: Agent] = [:]
    /// Each project's agents, by its standardized folder: archived ones too.
    private(set) var byFolder: [URL: Set<UUID>] = [:]
    /// The numbers a project's summary is made of, by folder. Only for folders with an agent.
    private(set) var tallies: [URL: ProjectTally] = [:]
    /// Moves whenever a folder gains its first agent or loses its last, so the project
    /// index knows when the set of folders is no longer what it was (#204).
    private(set) var foldersVersion = 0
    /// Agents starting or running: what keeps the Mac awake (024).
    private(set) var inFlight = 0
    /// Agents with a wait on events, open or ended (042). A handful at most.
    private(set) var withEventWait: Set<UUID> = []
    /// Agents holding a runtime: what keeps an idle daemon from exiting.
    private(set) var holdingRuntime = 0
    /// Each agent's folder as it was filed, so moving it takes it out of the right one.
    private var filedFolder: [UUID: URL] = [:]

    init() {}

    subscript(id: UUID) -> Agent? {
        get { live[id] ?? archived[id] }
        set {
            let before = live[id] ?? archived[id]
            let left = before.map { unfile($0) }
            live[id] = nil
            archived[id] = nil
            if let newValue {
                if newValue.state == .archived { archived[id] = newValue } else { live[id] = newValue }
                file(newValue)
            }
            // After the new copy is filed: an agent that held its project's newest
            // activity and is still the newest leaves nothing to look for.
            if let left { settle(left) }
            if let newValue, newValue.projectFolder != left { settle(newValue.projectFolder) }
        }
    }

    @discardableResult
    mutating func removeValue(forKey id: UUID) -> Agent? {
        let before = self[id]
        self[id] = nil
        return before
    }

    var count: Int { live.count + archived.count }
    var isEmpty: Bool { live.isEmpty && archived.isEmpty }
    /// Every agent, live first. A walk of everything: for the rare reader that needs it,
    /// never for something that runs on each change.
    var values: [Agent] { Array(live.values) + Array(archived.values) }
    var keys: [UUID] { Array(live.keys) + Array(archived.keys) }

    /// One project's agents, archived ones included, by its standardized folder.
    func agents(in folder: URL) -> [Agent] {
        (byFolder[folder] ?? []).compactMap { self[$0] }
    }

    /// The same for a folder as it was given: what every per-project count is handed,
    /// rather than every agent there is (#164).
    func inProject(_ folder: URL) -> [Agent] {
        agents(in: Project.standardize(folder))
    }

    // MARK: Filing

    private mutating func file(_ agent: Agent) {
        let folder = agent.projectFolder
        filedFolder[agent.id] = folder
        byFolder[folder, default: []].insert(agent.id)
        if tallies[folder] == nil { foldersVersion += 1 }
        tallies[folder, default: ProjectTally()].add(agent)
        if agent.state == .starting || agent.state == .running { inFlight += 1 }
        if agent.state.holdsRuntime { holdingRuntime += 1 }
        if agent.eventWait != nil { withEventWait.insert(agent.id) }
    }

    /// Out of every count, and the folder it was filed under.
    private mutating func unfile(_ agent: Agent) -> URL {
        let folder = filedFolder.removeValue(forKey: agent.id) ?? agent.projectFolder
        byFolder[folder]?.remove(agent.id)
        if byFolder[folder]?.isEmpty == true { byFolder[folder] = nil }
        tallies[folder]?.remove(agent)
        if agent.state == .starting || agent.state == .running { inFlight -= 1 }
        if agent.state.holdsRuntime { holdingRuntime -= 1 }
        withEventWait.remove(agent.id)
        return folder
    }

    private mutating func settle(_ folder: URL) {
        guard let members = byFolder[folder] else {
            if tallies.removeValue(forKey: folder) != nil { foldersVersion += 1 }
            return
        }
        guard tallies[folder]?.isStale == true else { return }
        let agents = members.compactMap { self[$0] }
        tallies[folder]?.settle(agents)
    }
}

/// One project's numbers, kept as its agents change (#164): what `ProjectSummary` says
/// of the agents in it, without walking them.
///
/// Counts and costs are added and taken away exactly (costs are `Decimal`). The newest
/// activity and the oldest start can't be taken away, so when the agent that held one
/// leaves or moves back it is found again from the folder's own agents, which is the
/// only walk, and of one project.
struct ProjectTally: Equatable {
    var members = 0
    var counts: [AgentGroup: Int] = [:]
    var costToDate: [String: Decimal] = [:]
    /// How many members carry each currency, so a currency nobody carries any more goes,
    /// as a full count would never have had it.
    var currencyHolders: [String: Int] = [:]
    var unmeasured = 0
    var newestActivity: Date?
    var oldestCreated: Date?
    /// The agent that held the newest activity, or the oldest start, has gone.
    private var newestLost = false
    private var oldestLost = false
    var isStale: Bool { newestLost || oldestLost }

    mutating func add(_ agent: Agent) {
        members += 1
        counts[agent.group(wantsEyes: false), default: 0] += 1
        for (currency, amount) in agent.costToDate {
            costToDate[currency, default: 0] += amount
            currencyHolders[currency, default: 0] += 1
        }
        if agent.isUnmeasured { unmeasured += 1 }
        if newestActivity.map({ agent.lastActivityAt >= $0 }) ?? true {
            newestActivity = agent.lastActivityAt
            newestLost = false
        }
        if oldestCreated.map({ agent.createdAt <= $0 }) ?? true {
            oldestCreated = agent.createdAt
            oldestLost = false
        }
    }

    mutating func remove(_ agent: Agent) {
        members -= 1
        let group = agent.group(wantsEyes: false)
        counts[group, default: 0] -= 1
        if counts[group] == 0 { counts[group] = nil }
        for (currency, amount) in agent.costToDate {
            currencyHolders[currency, default: 0] -= 1
            if currencyHolders[currency] == 0 {
                currencyHolders[currency] = nil
                costToDate[currency] = nil
            } else {
                costToDate[currency, default: 0] -= amount
            }
        }
        if agent.isUnmeasured { unmeasured -= 1 }
        if agent.lastActivityAt == newestActivity { newestLost = true }
        if agent.createdAt == oldestCreated { oldestLost = true }
    }

    /// Find the newest and oldest again from the folder's agents, after the one that
    /// held either has gone.
    mutating func settle(_ members: [Agent]) {
        if newestLost { newestActivity = members.map(\.lastActivityAt).max() }
        if oldestLost { oldestCreated = members.map(\.createdAt).min() }
        newestLost = false
        oldestLost = false
    }
}
