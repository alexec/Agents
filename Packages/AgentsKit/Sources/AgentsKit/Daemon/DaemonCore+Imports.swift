import Foundation
import AgentsKitCore

// MARK: Records from another root (#228)
//
// A scratch daemon whose root had been seeded with copies of the real root's agent
// records picked the live ones back up as running sessions — the same runtime session
// ids, in the same real folders — and one of them started a new agent whose worktree
// landed in the real repository. A record says which conversation and which folder;
// nothing on it said which daemon it belonged to.
//
// Three things close it:
// - every record is stamped with the id of the root it was made in, and a record with
//   another root's stamp is shown, stopped, and never run (`stampOrImport`);
// - a runtime session is claimed with a lock every daemon on this Mac sees, so one
//   live under another daemon is not driven a second time (`SessionClaims`);
// - a scratch daemon runs agents only inside its own root unless told otherwise
//   (`confinedTo`).

/// Which root this is: an id, and the path it was made at.
struct RootIdentity: Codable, Sendable {
    var id: String
    var path: String
    var madeAt: Date

    /// The id this root goes by, and whether it was made just now for a root that had
    /// none — the one start at which unstamped records are this root's own.
    ///
    /// A file written at another path is a root copied whole, and gets a new id: its
    /// records carry the old one, so they read as imported, which is what they are.
    /// It is not "new" in the sense that matters, so nothing unstamped is adopted.
    static func loadOrMake(at file: URL, root: URL) -> (id: String, adoptsUnstamped: Bool) {
        let here = root.resolvingSymlinksInPath().standardizedFileURL.path
        var adopts = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if FileManager.default.fileExists(atPath: file.path) {
            // A file there that cannot be read is not a root with none: nothing is adopted.
            adopts = false
        }
        if let data = try? Data(contentsOf: file),
           let kept = try? decoder.decode(RootIdentity.self, from: data) {
            if kept.path == here { return (kept.id, false) }
            DaemonLog.shared.write("root id \(kept.id) was made at \(kept.path), not \(here): a copied root; this one gets its own")
            adopts = false
        }
        let made = RootIdentity(id: UUID().uuidString, path: here, madeAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(made) { try? data.write(to: file, options: .atomic) }
        return (made.id, adopts)
    }
}

/// One lock per runtime session, held while this daemon has it live (#228).
///
/// A file lock, like `DaemonLock`, because it dies with the process: a daemon that
/// crashes holds nothing afterwards. Kept in a folder every daemon on this Mac shares —
/// `sharedFolder`, under the person's home — so a scratch daemon sees the real one's.
/// With no folder it claims nothing: a test that models a restart with a second core
/// beside a first that never dies hands one in only when the claim is what it tests.
struct SessionClaims {
    let folder: URL?
    /// Each session's lock, and the agents here holding it. Within one daemon two agents
    /// may share one (a test's fixtures do); the lock keeps out every other daemon.
    private var locks: [String: (lock: DaemonLock, holders: Set<UUID>)] = [:]
    private var keyOf: [UUID: String] = [:]

    init(folder: URL?) { self.folder = folder }

    /// Where every daemon on this Mac keeps its claims: beside the ordinary root, never
    /// inside one, so no root's copy carries them. `AGENTS_SESSION_LOCKS` overrides it.
    static func sharedFolder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let named = environment["AGENTS_SESSION_LOCKS"], !named.isEmpty {
            return URL(filePath: (named as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/Agents Session Locks", isDirectory: true)
        #else
        return home.appendingPathComponent(".local/state/agents/session-locks", isDirectory: true)
        #endif
    }

    static func key(runtimeID: String, sessionID: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let clean = { (text: String) in
            String(text.unicodeScalars.map { safe.contains($0) ? Character($0) : "_" })
        }
        // Long ids are cut, and the whole id's hash keeps two cut alike apart.
        let name = clean(runtimeID) + "--" + clean(sessionID)
        guard name.count > 180 else { return name }
        var hash: UInt64 = 1469598103934665603
        for byte in (runtimeID + "\u{0}" + sessionID).utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(name.prefix(160)) + "-" + String(hash, radix: 16)
    }

    /// Take the session for this agent, letting go of any other it held. False when
    /// another daemon already holds it.
    mutating func claim(_ agentID: UUID, runtimeID: String, sessionID: String) -> Bool {
        guard let folder else { return true }
        let key = Self.key(runtimeID: runtimeID, sessionID: sessionID)
        if keyOf[agentID] == key { return true }
        if locks[key] != nil {
            locks[key]?.holders.insert(agentID)
        } else {
            guard let lock = DaemonLock(at: folder.appendingPathComponent(key + ".lock")) else { return false }
            locks[key] = (lock, [agentID])
        }
        release(agentID)
        keyOf[agentID] = key
        return true
    }

    mutating func release(_ agentID: UUID) {
        guard let key = keyOf.removeValue(forKey: agentID), var entry = locks[key] else { return }
        entry.holders.remove(agentID)
        if entry.holders.isEmpty {
            entry.lock.release()
            locks.removeValue(forKey: key)
        } else {
            locks[key] = entry
        }
    }

    func holds(_ agentID: UUID) -> Bool { keyOf[agentID] != nil }
}

extension DaemonCore {
    /// Read this root's id, then stamp or import every record just loaded. Called from
    /// `loadFromDisk`, before `recover` looks at anything, so a copied record is never
    /// counted as work the last daemon was holding.
    func stampOrImport() async {
        let (id, adopts) = RootIdentity.loadOrMake(at: locations.rootIdentity, root: locations.root)
        rootID = id
        var adopted = 0
        var imported: [Agent] = []
        for agent in agents.values where agent.madeInRoot != id {
            if agent.madeInRoot == nil, adopts {
                var stamped = agent
                stamped.madeInRoot = id
                agents[agent.id] = stamped
                // A slim archived copy is safe to save: the store reads its lists back.
                try? await store.save(stamped)
                if stamped.state == .archived { indexEntry(for: stamped.id) }
                adopted += 1
            } else if agent.state != .archived {
                imported.append(agent)
            }
        }
        if adopted > 0 { DaemonLog.shared.write("root \(id): stamped \(adopted) record(s) made before stamps") }
        for agent in imported { await markImported(agent) }
    }

    /// Stopped, as imported, with nothing left on it that would start a runtime by
    /// itself: no wait to be woken from, no move to make, no park or follow-up to run.
    /// Written directly rather than through `move`, because a stop through the funnel
    /// fires the triggers, and a workflow run for a copy is the copy acting.
    private func markImported(_ agent: Agent) async {
        let alreadySaid = agent.state == .stopped && agent.endedReason == .imported
        var updated = agent
        updated.state = .stopped
        updated.endedReason = .imported
        updated.eventWait = nil
        updated.pendingMove = nil
        updated.parking = nil
        updated.afterTurn = nil
        updated.allowanceWait = nil
        guard !alreadySaid || updated != agent else { return }
        agents[agent.id] = updated
        try? await store.save(updated)
        DaemonLog.shared.write("agent \(agent.id) was made in root \(agent.madeInRoot ?? "unstamped"), not \(rootID ?? "?"): imported, stopped, never run here")
        if !alreadySaid {
            await record(.runtimeNote(RuntimeNote.imported), for: agent.id)
        }
    }

    /// Whether this record came from another root. False until this root's id is read.
    func isImported(_ agent: Agent) -> Bool {
        guard let rootID else { return false }
        return agent.madeInRoot != rootID
    }

    /// The one question asked before any runtime is started for an existing agent, and
    /// before a prompt to one is kept.
    func refuseToRun(_ agentID: UUID) throws {
        guard let agent = agents[agentID] else { return }
        if isImported(agent) {
            throw JSONRPCError(code: DaemonAPI.Failure.importedAgent, message: RuntimeNote.imported)
        }
        try refuseOutsideRoot(agent.cwd)
    }

    /// A scratch daemon's agents work inside its root (#228): a copied record, or a
    /// copied project list, otherwise points it at somebody's real repository.
    func refuseOutsideRoot(_ folder: URL) throws {
        guard let confinedTo else { return }
        let inside = confinedTo.resolvingSymlinksInPath().standardizedFileURL.path
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != inside, !path.hasPrefix(inside.hasSuffix("/") ? inside : inside + "/") else { return }
        throw JSONRPCError(code: DaemonAPI.Failure.outsideScratchRoot,
                           message: "This is a scratch daemon on \(inside), and \(path) is outside it. Start it with --allow-outside-root to run agents there.")
    }

    /// Claim the session an agent is about to continue, or say whose it is.
    func claimSession(_ agentID: UUID, runtimeID: String, sessionID: String) throws {
        guard sessionClaims.claim(agentID, runtimeID: runtimeID, sessionID: sessionID) else {
            DaemonLog.shared.write("agent \(agentID): \(runtimeID) session \(sessionID) is live under another daemon; not resumed")
            throw JSONRPCError(code: DaemonAPI.Failure.sessionLiveElsewhere,
                               message: "This conversation is already running under another Agents daemon on this Mac, so it was not started here as well.")
        }
    }

    /// For `Daemon`, which knows what process this is: the folder every daemon on this
    /// Mac shares, and the root a scratch daemon is kept inside.
    public func setSessionLocks(_ folder: URL) { sessionClaims = SessionClaims(folder: folder) }
    public func setConfinedTo(_ folder: URL?) { confinedTo = folder }
}
