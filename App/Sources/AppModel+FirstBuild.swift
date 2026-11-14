import AgentsKitCore
import Foundation

/// The first build (#5048, `specs/5048-first-build/spec.md`): who sees the question page
/// (#5050), what Submit does, and the plan page that follows it (#5053).
extension AppModel {
    /// The window paired with the control plane that the first open set up on this Mac:
    /// the question page stays until Submit, also across a quit.
    func keepAskingFirstBuild() {
        asksFirstBuild = true
        FirstBuildStore.asking = true
    }

    /// Only a newcomer sees the question page (section 9): once the lists are in, a control
    /// plane with a folder or an agent on it (an alpha's set-up, left as it was) is not new.
    /// The plan page goes when its session is archived (section 5).
    func weighFirstBuild() {
        // Only a session known to be archived: a list that does not have it yet is no answer.
        if firstBuildPlanning, let id = FirstBuildStore.agentID, let agent = work.agent(id), !agent.isFirstBuild {
            leaveFirstBuildPlan()
        }
        // New App… opened the page on purpose: a person with work on this Mac is meant to see it.
        guard asksFirstBuild, !firstBuildAnother, !needsFirstRun, hasLoadedFolders, hasLoadedAgents else { return }
        if !liveFolders.isEmpty || !agents.isEmpty { leaveFirstBuildQuestion() }
    }

    /// **New App…** (#5132): the question page again, for a person who is set up, with an empty
    /// box and Cancel. Submit starts one more first build, in a session of its own.
    func newApp() {
        guard !needsFirstRun else { return }
        leaveFirstBuildPlan()
        firstBuildIdea = nil
        FirstBuildStore.idea = nil
        chooseFirstBuildStarter(nil)
        firstBuildProblem = nil
        setFirstBuildAnother(true)
        keepAskingFirstBuild()
    }

    /// The question page's **Cancel**, after New App…: the usual window, as it was.
    func cancelNewApp() {
        leaveFirstBuildQuestion()
        setFirstBuildAnother(false)
        firstBuildIdea = nil
        FirstBuildStore.idea = nil
    }

    /// Submit, once the window is paired: the plan page takes the question page's place, with
    /// the starter the words pick (section 3), or none for the person to choose.
    func submitFirstBuild(_ idea: String) {
        firstBuildIdea = idea
        FirstBuildStore.idea = idea
        if case .starter(let starter) = FirstBuild.starter(for: idea) {
            chooseFirstBuildStarter(starter)
        } else {
            chooseFirstBuildStarter(nil)
        }
        firstBuildPlanning = true
        FirstBuildStore.planning = true
        firstBuildProblem = nil
        leaveFirstBuildQuestion()
    }

    /// The plan page's **Change**, or its choice for words that named no starter.
    func chooseFirstBuildStarter(_ starter: FirstBuild.Starter?) {
        firstBuildStarter = starter
        FirstBuildStore.starter = starter
    }

    /// **Back**, for an idea neither starter fits (section 4): the question page again, with
    /// the words still in the box.
    func backToFirstBuildQuestion() {
        let another = firstBuildAnother
        leaveFirstBuildPlan()
        setFirstBuildAnother(another)
        keepAskingFirstBuild()
    }

    /// **Open Agents** (section 5): the usual window, with the first-build session selected.
    /// The plan page does not come back on its own.
    func openAgentsFromFirstBuild() {
        let session = firstBuildAgent?.id
        leaveFirstBuildPlan()
        if let session { openAgent(session) }
    }

    /// The first-build session on this Mac: the one the plan page started or found, while it is
    /// not archived; else, for a newcomer, any labelled `first-build` (a second client's Submit).
    /// After New App…, only its own: the earlier first builds are other apps.
    var firstBuildAgent: Agent? {
        if let id = firstBuildAgentID, let agent = agents.first(where: { $0.id == id }) {
            // By its id: a record heard before its labels is still it, until it is archived.
            return agent.state != .archived && agent.archivedAt == nil ? agent : nil
        }
        if firstBuildAnother { return nil }
        return agents.first { $0.host == .mac && $0.isFirstBuild }
    }

    /// The runtime the first task sets up, as this Mac lists it.
    var firstBuildRuntime: RuntimeStatus? {
        runtimes.first { $0.id == firstBuildRuntimeID } ?? runtimes.first
    }

    /// What the plan page ticks its tasks from (section 6).
    var firstBuildFacts: FirstBuild.Facts {
        let agent = firstBuildAgent
        return FirstBuild.Facts(
            runtimeReady: firstBuildRuntime?.canStart == true,
            githubConnected: firstBuildGitHubConnected,
            plan: agent?.planInForce?.entries,
            waitsForPerson: agent.map { work.group(of: $0) == .needsAttention } ?? false)
    }

    /// Reads whether the `github` connector on this Mac is connected.
    func refreshFirstBuildGitHub() async {
        guard case .success(let connections) = await connections(on: .mac) else { return }
        let connected = connections.contains { $0.provider == .github && $0.state == .connected }
        if connected != firstBuildGitHubConnected { firstBuildGitHubConnected = connected }
    }

    /// Starts the agent once the app's two tasks are done and a starter is chosen (section 7).
    /// A first build there already (a second client's Submit) is the session the page shows.
    func startFirstBuildIfReady() async {
        // One start per page: a session kept by its id that the list does not have yet is no gap.
        guard firstBuildPlanning, firstBuildAgent == nil, firstBuildAgentID == nil, !firstBuildStarting, firstBuildProblem == nil,
              let idea = firstBuildIdea, let starter = firstBuildStarter,
              let runtime = firstBuildRuntime, FirstBuild.canStart(firstBuildFacts),
              let wireStarter = DaemonAPI.FirstBuildStartRequest.Starter(rawValue: starter.rawValue) else { return }
        firstBuildStarting = true
        defer { firstBuildStarting = false }
        do {
            let id = try await client(for: .mac).call(DaemonAPI.Method.firstBuildStart,
                                                         DaemonAPI.FirstBuildStartRequest(idea: idea, starter: wireStarter,
                                                                                          runtimeID: runtime.id,
                                                                                          another: firstBuildAnother ? true : nil),
                                                         returning: UUID.self)
            keepFirstBuildSession(id)
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.firstBuildRunning {
            if let id = error.data?["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)) { keepFirstBuildSession(id) }
        } catch let error as JSONRPCError {
            firstBuildProblem = error.message
        } catch {
            firstBuildProblem = "Agent Loops on this Mac did not answer, so the agent did not start."
        }
        await refreshAgents()
    }

    /// **Try Again** after a start that failed.
    func retryFirstBuildStart() async {
        firstBuildProblem = nil
        await startFirstBuildIfReady()
    }

    private func keepFirstBuildSession(_ id: UUID) {
        firstBuildAgentID = id
        FirstBuildStore.agentID = id
        if selection != id { selection = id }
    }

    private func leaveFirstBuildQuestion() {
        asksFirstBuild = false
        FirstBuildStore.asking = false
    }

    private func leaveFirstBuildPlan() {
        firstBuildPlanning = false
        FirstBuildStore.planning = false
        firstBuildAgentID = nil
        FirstBuildStore.agentID = nil
        setFirstBuildAnother(false)
    }

    private func setFirstBuildAnother(_ another: Bool) {
        firstBuildAnother = another
        FirstBuildStore.another = another
    }
}

/// The question page and the plan page's state, in `WindowDefaults`, so a scratch copy does
/// not answer the real app's. The session itself is the record:
/// this keeps only where the window is, and the idea until the agent has it.
enum FirstBuildStore {
    static var asking: Bool {
        get { WindowDefaults.store.bool(forKey: "firstBuild.asking") }
        set { WindowDefaults.store.set(newValue, forKey: "firstBuild.asking") }
    }

    static var planning: Bool {
        get { WindowDefaults.store.bool(forKey: "firstBuild.planning") }
        set { WindowDefaults.store.set(newValue, forKey: "firstBuild.planning") }
    }

    static var idea: String? {
        get { WindowDefaults.store.string(forKey: "firstBuild.idea") }
        set { WindowDefaults.store.set(newValue, forKey: "firstBuild.idea") }
    }

    static var starter: FirstBuild.Starter? {
        get { WindowDefaults.store.string(forKey: "firstBuild.starter").flatMap(FirstBuild.Starter.init(rawValue:)) }
        set { WindowDefaults.store.set(newValue?.rawValue, forKey: "firstBuild.starter") }
    }

    static var another: Bool {
        get { WindowDefaults.store.bool(forKey: "firstBuild.another") }
        set { WindowDefaults.store.set(newValue, forKey: "firstBuild.another") }
    }

    static var agentID: UUID? {
        get { WindowDefaults.store.string(forKey: "firstBuild.agentID").flatMap(UUID.init(uuidString:)) }
        set { WindowDefaults.store.set(newValue?.uuidString, forKey: "firstBuild.agentID") }
    }
}
