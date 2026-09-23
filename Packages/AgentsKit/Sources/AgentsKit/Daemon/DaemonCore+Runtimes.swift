import Foundation

/// Signing in, signing out, choosing a provider, and the sessions a runtime is holding.
///
/// All of it needs a live runtime to ask, and none of it belongs to an agent, so each
/// call starts a runtime, asks, and lets it go again. That is a second or two, and it
/// is the difference between the app being able to fix a signed-out runtime and telling
/// the user to go and use a terminal.
extension DaemonCore {
    // MARK: The account

    public func refreshAccount(runtimeID: String) async throws -> RuntimeAccount {
        let (session, handshake) = try await handshakeOnly(runtimeID: runtimeID)
        defer { Task { await session.end(gracePeriod: .seconds(2)) } }
        noteAccount(runtimeID: runtimeID, from: handshake)
        if handshake.supportsProviders, let providers = try? await session.providers() {
            var account = account(for: runtimeID)
            account.providers = providers.providers ?? []
            account.currentProviderID = providers.currentProviderId
            accounts[runtimeID] = account
            broadcast(DaemonAPI.Notification.runtimeAccountChanged, account)
        }
        return account(for: runtimeID)
    }

    public func authenticate(runtimeID: String, methodID: String) async throws -> RuntimeAccount {
        let (session, handshake) = try await handshakeOnly(runtimeID: runtimeID)
        defer { Task { await session.end(gracePeriod: .seconds(2)) } }
        let method = (handshake.authMethods ?? []).first { $0.id == methodID }
        if let command = method?.terminalCommand {
            // The runtime says this one needs a terminal. We hand back the command it
            // named rather than running it: it is interactive, and it is theirs.
            throw JSONRPCError(code: DaemonAPI.Failure.needsSignIn,
                               message: "Run this in a terminal: \(command)",
                               data: ["command": .string(command), "runtimeID": .string(runtimeID)])
        }
        do {
            try await session.authenticate(methodID: methodID)
        } catch let error as JSONRPCError {
            markNeedsSignIn(runtimeID: runtimeID)
            throw JSONRPCError(code: DaemonAPI.Failure.needsSignIn,
                               message: "That did not sign in: \(error.message)")
        }
        var account = account(for: runtimeID)
        account.state = .ready
        account.checkedAt = Date()
        accounts[runtimeID] = account
        broadcast(DaemonAPI.Notification.runtimeAccountChanged, account)
        return account
    }

    /// Sign out, after saying which agents it stops. Those agents are mid-conversation,
    /// so this is not a quiet thing to do.
    public func logOut(runtimeID: String) async throws -> [UUID] {
        let stopped = agents.values.filter { $0.runtimeID == runtimeID && $0.state.holdsRuntime }.map(\.id)
        for id in stopped { try? await stop(id) }
        let (session, _) = try await handshakeOnly(runtimeID: runtimeID)
        defer { Task { await session.end(gracePeriod: .seconds(2)) } }
        try await session.logOut()
        markNeedsSignIn(runtimeID: runtimeID)
        return stopped
    }

    public func setProvider(runtimeID: String, providerID: String) async throws -> RuntimeAccount {
        let (session, _) = try await handshakeOnly(runtimeID: runtimeID)
        defer { Task { await session.end(gracePeriod: .seconds(2)) } }
        try await session.setProvider(id: providerID)
        var account = account(for: runtimeID)
        account.currentProviderID = providerID
        accounts[runtimeID] = account
        broadcast(DaemonAPI.Notification.runtimeAccountChanged, account)
        return account
    }

    // MARK: The sessions a runtime is holding

    /// What this runtime has in this folder, including conversations this app did not
    /// start. Ones we already hold are flagged rather than hidden, so the list is the
    /// truth about the runtime rather than a filtered view of it.
    public func listRuntimeSessions(runtimeID: String, cwd: URL) async throws -> [RuntimeSession] {
        let (session, _) = try await handshakeOnly(runtimeID: runtimeID)
        defer { Task { await session.end(gracePeriod: .seconds(2)) } }
        let held = Set(agents.values.filter { $0.runtimeID == runtimeID }.compactMap(\.runtimeSessionID))
        return try await session.listSessions(cwd: cwd).map { summary in
            RuntimeSession(sessionID: summary.sessionId,
                           cwd: URL(filePath: summary.cwd ?? cwd.path),
                           additionalDirectories: (summary.additionalDirectories ?? []).map { URL(filePath: $0) },
                           title: summary.title,
                           updatedAt: summary.updatedAt,
                           isHeld: held.contains(summary.sessionId))
        }
    }

    /// Take a conversation this app did not start and make it an agent.
    ///
    /// Its history is whatever `session/load` replays, which is the one place a replay
    /// is content rather than noise: we have no record of our own for it.
    public func adopt(runtimeID: String, sessionID: String, cwd: URL) async throws -> UUID {
        if let existing = agents.values.first(where: {
            $0.runtimeID == runtimeID && $0.runtimeSessionID == sessionID
        }) {
            return existing.id
        }
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "There is no runtime called \(runtimeID).")
        }
        let (session, handshake) = try await handshakeOnly(runtimeID: runtimeID)
        guard handshake.supportsLoad else {
            await session.end(gracePeriod: .seconds(2))
            throw JSONRPCError(code: DaemonAPI.Failure.notSupported,
                               message: "\(runtime.name) cannot hand a conversation over.")
        }

        var agent = Agent(runtimeID: runtimeID,
                          cwd: cwd,
                          title: nil,
                          state: .finished,
                          runtimeSessionID: sessionID,
                          endedReason: .endTurn)
        agents[agent.id] = agent
        try await store.save(agent)
        live[agent.id] = session
        listen(to: session, agentID: agent.id)
        await record(.runtimeNote("Picked up a conversation \(runtime.name) was already holding."),
                     for: agent.id)
        // The replay is the transcript, so this one is recorded rather than discarded.
        await session.setReplayRecorded(true)
        try await session.continueSession(id: sessionID, cwd: cwd)
        await session.setReplayRecorded(false)
        agent = agents[agent.id] ?? agent
        // Empty is not an answer, for either of them. A runtime that sends its options
        // or its commands as a `session/update` rather than on the `session/new` result
        // has none at this instant, and writing that over a record that already had some
        // leaves the row under the prompt with nothing to draw, and the slash list empty,
        // until the notification lands — or for good, where a runtime advertises them
        // once and a picked-up session never says it again.
        // `ACPSession.setOption` already guards the same assignment the same way.
        let refreshed = await session.options
        if !refreshed.isEmpty { agent.advertisedOptions = refreshed }
        let commands = await session.commands
        if !commands.isEmpty { agent.availableCommands = commands }
        changed(agent)
        await releaseRuntime(for: agent.id)
        return agent.id
    }

    /// Branch an agent. The original is untouched and keeps its own transcript; the new
    /// one starts with a copy of it.
    public func fork(agentID: UUID) async throws -> UUID {
        guard let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard let sessionID = agent.runtimeSessionID else {
            throw JSONRPCError(code: DaemonAPI.Failure.sessionGone,
                               message: "That agent has no conversation to branch yet.")
        }
        let (session, handshake) = try await handshakeOnly(runtimeID: agent.runtimeID)
        defer { Task { await session.end(gracePeriod: .seconds(2)) } }
        guard handshake.supportsFork else {
            throw JSONRPCError(code: DaemonAPI.Failure.notSupported,
                               message: "\(agent.runtimeID) cannot branch a conversation.")
        }
        try await session.continueSession(id: sessionID, cwd: agent.cwd)
        let forked = try await session.forkSession(cwd: agent.cwd,
                                                   additionalDirectories: agent.additionalDirectories,
                                                   meta: ToolPolicyCatalog.policy(for: agent.runtimeID).sessionMeta)

        // A new agent carrying the conversation, not a copy of the record. What the
        // original was doing, owes, has queued or was started by is the original's: a
        // branch taken from a running agent copied `running` with no runtime behind it,
        // which queued its prompts for ever and kept the daemon open.
        let copy = Agent(runtimeID: agent.runtimeID,
                         cwd: agent.cwd,
                         title: agent.title.map { "\($0) (branch)" },
                         state: .finished,
                         runtimeSessionID: forked,
                         startOptions: agent.startOptions,
                         advertisedOptions: agent.advertisedOptions,
                         availableCommands: agent.availableCommands,
                         endedReason: .endTurn,
                         additionalDirectories: agent.additionalDirectories,
                         mcpServers: agent.mcpServers)
        agents[copy.id] = copy
        try await store.save(copy)
        // The history so far is ours, so the branch starts with a copy of it rather
        // than with whatever the runtime chooses to replay.
        let page = try await store.transcript(for: agent.id, before: nil, limit: 10_000)
        for entry in page.entries { try? await store.append(entry, for: copy.id) }
        await record(.runtimeNote("Branched from \(agent.title ?? "another agent")."), for: copy.id)
        changed(copy)
        return copy.id
    }

    /// Remove a conversation from the runtime. Permanent, so it happens only when the
    /// caller says it meant it.
    public func deleteRuntimeSession(runtimeID: String, sessionID: String, confirmed: Bool) async throws {
        guard confirmed else {
            throw JSONRPCError(code: DaemonAPI.Failure.notConfirmed,
                               message: "Deleting a conversation cannot be undone. Confirm it first.")
        }
        let (session, _) = try await handshakeOnly(runtimeID: runtimeID)
        defer { Task { await session.end(gracePeriod: .seconds(2)) } }
        try await session.deleteSession(id: sessionID)
        for agent in agents.values where agent.runtimeID == runtimeID && agent.runtimeSessionID == sessionID {
            var updated = agent
            updated.runtimeSessionID = nil
            changed(updated)
            await record(.runtimeNote("The runtime's copy of this conversation was deleted."),
                         for: agent.id)
        }
    }

    // MARK: Asking a runtime something without starting an agent

    func handshakeOnly(runtimeID: String) async throws -> (ACPSession, ACP.InitializeResult) {
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "There is no runtime called \(runtimeID).")
        }
        guard case .available(let path, _) = discovery.locate(runtime) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "\(runtime.name) is not installed, or is not where we looked.")
        }
        let session = try launcher.launch(runtime: runtime, path: path, cwd: locations.root)
        do {
            let handshake = try await session.initialize()
            noteAccount(runtimeID: runtimeID, from: handshake)
            return (session, handshake)
        } catch {
            await session.end(gracePeriod: .seconds(1))
            throw error
        }
    }
}
