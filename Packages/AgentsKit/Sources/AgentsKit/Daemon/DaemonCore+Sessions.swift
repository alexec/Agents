import Foundation

/// An agent listing the sessions in its project and reading one (065).
///
/// So the person can say "continue the work of Login redirect" to a new chat on any
/// runtime. The project is the caller's own, taken from its token; there is no way to
/// name another. Nothing here writes: no transcript line, no activity time, no
/// broadcast. A session read is the session it was.
///
/// Every agent may, including one another agent started: reading is not managing
/// anyone, and a helper continuing a teammate's work is the same act. Nobody is asked
/// first, because the sessions are the person's own and nothing leaves the project.
extension DaemonCore {
    public func labelVocabulary(_ request: DaemonAPI.LabelVocabularyRequest) -> [String] {
        SessionLabelPolicy.vocabulary(in: request.folder, agents: agents.inProject(request.folder)).map(\.value)
    }

    /// A window or paired device changes labels as the person. The daemon assigns
    /// ownership and saves the complete result in a single broadcast.
    public func setSessionLabels(_ request: DaemonAPI.SetLabelsRequest) throws -> Agent {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That session no longer exists.")
        }
        do {
            agent.labels = try SessionLabelPolicy.change(
                current: agent.labels, add: request.add, remove: request.remove,
                actor: .person,
                projectLabels: SessionLabelPolicy.vocabulary(in: agent.projectFolder, agents: agents.inProject(agent.projectFolder)))
        } catch {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: error.localizedDescription)
        }
        changed(agent)
        return agent
    }

    public func listSessions(_ request: DaemonAPI.ListSessionsRequest) async throws -> String {
        let caller = try sessionCaller(token: request.token)
        await settle(loadLeasesIfNeeded())
        let sessions = agents.inProject(caller.projectFolder)
        var holding: [UUID: [String]] = [:]
        for agent in sessions {
            let held = leaseBook.held(by: agent.id).map(\.resource.key)
            if !held.isEmpty { holding[agent.id] = held }
        }
        return SessionLookup.list(in: caller.projectFolder, agents: sessions, caller: caller.id, holding: holding,
                                  limit: request.limit, after: request.after)
    }

    /// The history, or the sentence saying why not. A refusal is a normal result the
    /// agent reads, not an error: it can list the sessions and try again.
    public func readSession(_ request: DaemonAPI.ReadSessionRequest) async throws -> String {
        let caller = try sessionCaller(token: request.token)
        switch SessionLookup.find(request.session, in: caller.projectFolder,
                                  agents: agents.inProject(caller.projectFolder), retired: retired.values) {
        case .refused(let sentence):
            return sentence
        case .session(let agent):
            // A successor reads the session it carries on, and may then take its tiles (074).
            noteSessionRead(agent.id, by: caller.id)
            let header = SessionHistory.Header(
                id: agent.id, title: agent.title, runtime: PoolWords.runtimeName(agent.runtimeID),
                status: SessionLookup.status(of: agent), folder: agent.cwd.path,
                worktree: agent.worktree.map { .init(name: $0.name, branch: $0.branch) })
            guard let document = await history(of: agent.id, header: header) else {
                return SessionLookup.unavailable
            }
            return document.markdown
        }
    }

    /// The first turn and the latest, read a page at a time into a builder that keeps
    /// only what fits. At most `historyBytes` of transcript is read, from the end back,
    /// so a lead polling a helper of tens of megabytes no longer decodes it all (#210).
    func history(of agentID: UUID, header: SessionHistory.Header,
                 bytes: Int = DaemonCore.historyBytes) async -> SessionHistory.Document? {
        guard let lines = try? await store.historyLines(for: agentID, bytes: bytes) else { return nil }
        var builder = SessionHistory.Builder(runtime: header.runtime)
        // The first turn, then each of the latest, each ended before the next begins.
        let turns = [lines.first] + lines.latest
        for (position, ranges) in turns.enumerated() {
            for range in ranges {
                var next = range.lowerBound
                while next < range.upperBound {
                    let end = min(next + Self.historyPage, range.upperBound)
                    guard let page = try? await store.transcript(for: agentID, before: end, limit: end - next) else {
                        return nil
                    }
                    for entry in page.entries { builder.add(entry) }
                    next = end
                }
            }
            if position == 0 { builder.leaveOut(lines.leftOut) } else { builder.endTurn() }
        }
        // The plan as it last stood, wherever in the session it was set.
        if let plan = lines.plan,
           let page = try? await store.transcript(for: agentID, before: plan + 1, limit: 1) {
            for entry in page.entries { builder.add(entry) }
        }
        return builder.document(header: header)
    }

    static let historyPage = 500
    /// Transcript bytes one `read_session` reads at most (#210).
    /// A megabyte holds a dozen times what the 80,000-character history can show.
    static let historyBytes = 1 << 20

    /// The agent a token speaks for. Any agent: a helper reads as its lead does.
    private func sessionCaller(token: String) throws -> Agent {
        guard let callerID = appTokens[token], let caller = agents[callerID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was read.")
        }
        return caller
    }
}
