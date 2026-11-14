import AgentsKitCore
import AppKit
import Foundation
import os

/// Sessions the app did not start, and the forms that answer them.
extension AppModel {
    // MARK: Sessions the app did not start

    func runtimeSessions(runtimeID: String, cwd: URL) async -> [RuntimeSession] {
        do {
            return try await selectedHostClient.call(DaemonAPI.Method.sessionsList,
                                         DaemonAPI.SessionsListRequest(runtimeID: runtimeID, cwd: cwd),
                                         returning: [RuntimeSession].self)
        } catch {
            problem = describe(error)
            return []
        }
    }

    func adopt(runtimeID: String, session: RuntimeSession) async {
        do {
            let id = try await selectedHostClient.call(DaemonAPI.Method.sessionsAdopt,
                                           DaemonAPI.AdoptRequest(runtimeID: runtimeID,
                                                                  sessionID: session.sessionID,
                                                                  cwd: session.cwd),
                                           returning: UUID.self)
            await refreshAgents()
            selection = id
        } catch {
            fail(error, on: selectedFolderHost)
        }
    }

    func deleteRuntimeSession(runtimeID: String, sessionID: String) async {
        await attempt {
            try await self.selectedHostClient.call(DaemonAPI.Method.sessionsDelete,
                                       DaemonAPI.DeleteSessionRequest(runtimeID: runtimeID,
                                                                      sessionID: sessionID,
                                                                      confirmed: true))
        }
    }

    func fork(_ id: UUID) async {
        do {
            let branch = try await client(forAgent: id).call(DaemonAPI.Method.agentsFork,
                                               DaemonAPI.AgentRequest(agentID: id),
                                               returning: UUID.self)
            await refreshAgents()
            selection = branch
        } catch {
            problem = describe(error)
        }
    }

    /// Branch from Here (#1658): a new session from just before one of the person's prompts,
    /// opened as Branch opens one, with that prompt in its bar to change and send. The words
    /// go in as the new session's draft, so its bar has them however it comes on screen.
    /// Undo These Changes on a turn's card (#3437): the turn's files back as they were
    /// before it. Thrown errors are the card's to say.
    func undoTurn(_ turn: UUID, of agentID: UUID, confirmed: Bool) async throws -> DaemonAPI.UndoTurnResult {
        try await client(forAgent: agentID).call(DaemonAPI.Method.changesUndoTurn,
                                                 DaemonAPI.UndoTurnRequest(agentID: agentID, turn: turn,
                                                                           confirmed: confirmed ? true : nil),
                                                 returning: DaemonAPI.UndoTurnResult.self)
    }

    func branch(from entryID: UUID, of agentID: UUID, text: String) async {
        do {
            let branch = try await client(forAgent: agentID).call(DaemonAPI.Method.agentsBranchFrom,
                                               DaemonAPI.BranchFromRequest(agentID: agentID, entryID: entryID),
                                               returning: UUID.self)
            DraftKeeper.shared.note(text, [], for: .agent(branch))
            await refreshAgents()
            selection = branch
        } catch {
            problem = describe(error)
        }
    }

    /// An answer pressed on a banner (#1170): the card's own answer, through the same call.
    /// A question no longer held was answered somewhere else, and nothing is sent: the
    /// daemon would refuse it, and its banner goes with the next sweep.
    func answerFromBanner(_ token: String, _ quick: QuickAnswer, typed: String?) async {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let sent: Bool
        switch parts[0] {
        case "permission":
            guard let request = permissions.first(where: { $0.id.uuidString == parts[1] }) else {
                note("banner: \(token) is over, nothing sent")
                return
            }
            sent = await answer(request, optionID: quick.id)
        case "elicitation":
            guard let request = elicitations.first(where: { $0.id.uuidString == parts[1] }),
                  let content = quick.content(typed: typed) else {
                note("banner: \(token) is over, or nothing typed; nothing sent")
                return
            }
            sent = await answerElicitation(request, action: .accept, content: content)
        case "request":
            guard let request = work.requests.first(where: { $0.id.uuidString == parts[1] }),
                  let action = NeedRequest.Action(rawValue: quick.id) else {
                note("banner: \(token) is over, nothing sent")
                return
            }
            sent = await answerSecretUse(request, action)
        default:
            return
        }
        note("banner: \(token) \(quick.kind.rawValue) \(sent ? "answered" : "not sent")")
    }

    /// A person's answer to a secret's use (#4017), from its Needs you row or its banner: to
    /// the host of the session that asked. Whether it went; why not is the problem.
    @discardableResult
    func answerSecretUse(_ request: NeedRequest, _ action: NeedRequest.Action) async -> Bool {
        let host = host(ofAgent: request.askedBy)
        var approval: DaemonAPI.LockDelivery?
        // A Linux machine opens the value only for an answer this Mac signed (#4149).
        if let use = request.secretUse, use.signs(action) {
            guard let signer = await lock.channelSigner(),
                  let signed = try? LockChannel.secretUseApproval(signer.key, to: host.rawValue, request: request.id,
                                                                  use: use, action: action) else {
                problem = "Not sent — this machine opens the secret only for an answer your device signs, and this Mac is not in your lock. Answer on the Remote."
                return false
            }
            approval = signed
        }
        let answer = DaemonAPI.RequestsAnswer(id: request.id, secretUse: action, approval: approval)
        return await attempt(on: host) {
            let update = try await self.client(forAgent: request.askedBy)
                .call(DaemonAPI.Method.requestsAnswer, answer, returning: DaemonAPI.RequestUpdate.self)
            self.work.replaceRequests(self.work.requests.filter { $0.id != update.request.id })
        }
    }

    /// Later on a request (#4234), from its Needs you row or its card: to the host of the
    /// session that asked. It stays open, in Later, until it comes back.
    @discardableResult
    func deferRequest(_ request: NeedRequest, _ params: DaemonAPI.RequestsDefer) async -> Bool {
        let sent = await work.changing(request, to: request.deferring(params)) {
            await changeRequest(request, DaemonAPI.Method.requestsDefer, params)
        }
        // Undo is Bring Back Now (#4793).
        if sent { offer(SessionUndo.later(request)) }
        return sent
    }

    /// Bring back now (#4234): out of Later, to the top of Needs you.
    @discardableResult
    func undeferRequest(_ request: NeedRequest) async -> Bool {
        await work.changing(request, to: request.broughtBack) {
            await changeRequest(request, DaemonAPI.Method.requestsUndefer, DaemonAPI.RequestsUndefer(id: request.id))
        }
    }

    func changeRequest(_ request: NeedRequest, _ method: String, _ params: some Encodable & Sendable) async -> Bool {
        await attempt(on: host(ofAgent: request.askedBy)) {
            let update = try await self.client(forAgent: request.askedBy)
                .call(method, params, returning: DaemonAPI.RequestUpdate.self)
            self.work.apply(.requestChanged(update.request))
        }
    }

    // MARK: Forms

    /// Whether the answer went, as `answer(_:optionID:)` (#86).
    @discardableResult
    func answerElicitation(_ request: ElicitationRequest,
                           action: DaemonAPI.AnswerElicitationRequest.Action,
                           content: [String: JSONValue] = [:], reason: String? = nil) async -> Bool {
        let sendID = UUID()
        // An empty reason is No thanks (#4039).
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The card goes at once, and comes back if the answer did not go (#4786).
        let sent = await work.answering(request) { await attempt {
            try await self.client(forAgent: request.agentID).call(DaemonAPI.Method.elicitationsAnswer,
                                       DaemonAPI.AnswerElicitationRequest(requestID: request.id,
                                                                          action: action,
                                                                          content: content,
                                                                          sendID: sendID,
                                                                          reason: reason?.isEmpty == false ? reason : nil))
        } }
        await refreshElicitations()
        return sent
    }

    func dismissProblem() { problem = nil }

    /// Something the window worked out for itself, said the same way as anything the
    /// daemon says.
    func show(problem: String) { self.problem = problem }

    /// Whether the work went through, for the callers that must undo something when
    /// it did not.
    @discardableResult
    /// Files attached from this Mac, copied to the server first (037, FR-015). A path
    /// on the Mac means nothing to an agent on a server, so each file that exists here
    /// is written into the agent's folder there, and the attachment points at that
    /// copy. Pictures already travel as bytes, and a file named from the server's own
    /// files pane is already a path there. Nil, with the reason said, when a file
    /// cannot go: the prompt then stays in the field.
    func carry(_ attachments: [Attachment], to host: MachineRef, for agentID: UUID) async -> [Attachment]? {
        var carried: [Attachment] = []
        for attachment in attachments {
            guard case .resourceLink(let uri, let name, let mimeType, _, _) = attachment.block,
                  let url = URL(string: uri), url.isFileURL,
                  let agent = work.agent(agentID),
                  !url.path.hasPrefix(agent.cwd.path),
                  FileManager.default.fileExists(atPath: url.path) else {
                carried.append(attachment)
                continue
            }
            // Looked at before it is read, and read off the main thread (#930): a film
            // attached by mistake is refused at once, not after it is read whole.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= DaemonAPI.attachmentLimit else {
                problem = "\(name) is too big to send to \(hosts.label(host))."
                return nil
            }
            let data: Data
            do {
                data = try await Task.detached {
                    try Data(contentsOf: url)
                }.value
            } catch {
                // Not "too big": a file this window may not read, or one gone, says so (073).
                problem = "\(name) could not be read to send to \(hosts.label(host)): \(error.localizedDescription)"
                return nil
            }
            guard data.count <= DaemonAPI.attachmentLimit else {
                problem = "\(name) is too big to send to \(hosts.label(host))."
                return nil
            }
            do {
                let written = try await client(for: host).call(
                    DaemonAPI.Method.filesWrite, DaemonAPI.FilesWriteRequest(agentID: agentID, name: name, data: data),
                    returning: DaemonAPI.FilesWriteResponse.self)
                carried.append(Attachment(block: .resourceLink(uri: URL(filePath: written.path).absoluteString,
                                                               name: name, mimeType: mimeType, size: data.count),
                                          displayName: attachment.displayName, byteCount: data.count))
            } catch {
                problem = "\(name) could not be sent to \(hosts.label(host))."
                return nil
            }
        }
        return carried
    }

    /// A send to a server, delivered once or reported as not sent (037, FR-020).
    ///
    /// The caller makes the `sendID` once, so every retry here is the same send: a
    /// daemon that acted on the first try and lost its reply with the connection answers
    /// the retry as it did, and acts once. A transport error is retried as the server
    /// comes back, for up to 30 seconds; a refusal from the daemon is its answer and is
    /// not retried.
    func sendToServer(_ host: MachineRef,
                              _ work: @escaping (DaemonClient) async throws -> Void) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do {
                try await work(client(for: host))
                return true
            } catch let refused as JSONRPCError where refused.code == DaemonAPI.Failure.kept {
                // Kept for a stopped workspace (#691 US3): its bubble says so; it goes when the host is up.
                noteKept(refused)
                return true
            } catch let refused as JSONRPCError {
                fail(refused, on: host)
                return false
            } catch {
                guard ContinuousClock.now < deadline else {
                    problem = "Not sent — \(hosts.label(host)) went offline."
                    return false
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @discardableResult
    /// `quietWhenDown`: a server the offline strip already explains raises no alert (#963),
    /// and neither does this Mac's own refresh with no host on this Mac (#1503).
    func attempt(on host: MachineRef = .mac, quietWhenDown: Bool = false, _ work: () async throws -> Void) async -> Bool {
        // Already known to be quiet: said now, naming why, not after waiting out a
        // connect the reconnect loop is already making (#83, #303). The strip has Try Again.
        // With no host on this Mac, nothing is asked: a pane's own refresh (quiet) says
        // nothing, as the pane says it; what a person asked for says there is none (#1503).
        if host == .mac, noHostOnThisMac {
            if !quietWhenDown { problem = HostSet.noMacHostProblem }
            return false
        }
        if host == .mac, !controlPlaneAway, hosts.isOffline(macHostElsewhere ?? .mac) || macHostNotice != nil {
            problem = macHostNotice?.action ?? HostSet.macDownProblem
            return false
        }
        do {
            try await work()
            return true
        } catch {
            // One retry through a fresh connection: the daemon having gone idle is not
            // something the user should have to know about.
            if !isConnected {
                await connect()
                if isConnected, (try? await work()) != nil { return true }
            }
            if quietWhenDown, host != .mac, hosts.isOffline(host) || OfflineWords.hostDown(error) { return false }
            fail(error, on: host)
            return false
        }
    }

    /// A failure put in front of the person. A runtime of this Mac's that needs signing
    /// in gets its sign-in sheet; everything else is said in words. A server's runtime
    /// is signed in on the server, which this sheet cannot do, so it stays words.
    func fail(_ error: any Error, on host: MachineRef) {
        if error is SaidAlready { return }
        if host == .mac, let error = error as? JSONRPCError, error.code == DaemonAPI.Failure.needsSignIn,
           let runtimeID = error.data?["runtimeID"]?.stringValue {
            signInRuntimeID = runtimeID
            return
        }
        // A server's Claude signs in through this Mac's own sign-in (056): with none to
        // relay, the sheet that signs it in on this Mac, and a sentence saying so.
        if host != .mac, let error = error as? JSONRPCError, error.code == DaemonAPI.Failure.signInWanted,
           let wanted = try? error.data?.decode(DaemonAPI.SignInWanted.self) {
            problem = error.message + " Sign it in on this Mac, or use \(hosts.label(host))’s own sign-in in Settings ▸ Machines."
            signInRuntimeID = wanted.runtime
            return
        }
        problem = describe(error)
    }

    /// The sign-in sheet, put away. Signed in or not, it does not come back for this
    /// runtime by itself until the runtime has been signed in once more.
    func putAwaySignIn() {
        if let runtimeID = signInRuntimeID, accounts[runtimeID]?.state != .ready {
            signInsPutAway.insert(runtimeID)
        }
        signInRuntimeID = nil
    }

    /// What a person can read. The daemon's errors are already written for someone
    /// looking at a screen, so they are shown as they are.
    func describe(_ error: any Error) -> String {
        if let error = error as? JSONRPCError {
            // A runtime that needs signing in says so, and says how. The command is
            // the runtime's own, which is better advice than any we could invent.
            if error.code == DaemonAPI.Failure.needsSignIn,
               let methods = try? error.data?["authMethods"]?.decode([ACP.AuthMethod].self),
               let command = methods.compactMap(\.terminalCommand).first {
                return "\(error.message). Run: \(command)"
            }
            return error.message
        }
        if let error = error as? DaemonClient.ConnectError {
            switch error {
            case .couldNotConnect:
                return macHostNotice?.action ?? HostSet.macDownProblem
            case .socketPathTooLong(let path):
                // Only ever seen by somebody who passed `--root`, and the fix is in
                // their hands: a shorter path.
                return "That folder is too deep to run a daemon in: \(path) is past the 104 bytes a socket may be named with."
            }
        }
        // This window's own writes: a full disk or a refused folder, in words (#88).
        if let failure = WriteFailure(error, keeping: "that") { return failure.message }
        return String(describing: error)
    }
}
