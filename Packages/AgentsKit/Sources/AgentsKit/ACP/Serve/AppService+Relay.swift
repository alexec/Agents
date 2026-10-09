import Foundation

extension AppService {
    /// The daemon method behind a tool, called with the request it takes. The daemon's
    /// own `handle`, for the loopback endpoint (#185).
    public typealias Relay = @Sendable (String, JSONValue) async -> Result<JSONValue, JSONRPCError>

    /// The app's tools for one agent: every tool does the same thing with what it is
    /// given, which is hand it to the daemon with the agent's token and repeat what the
    /// daemon says back to the agent. Nothing is decided here.
    ///
    /// This was the `agentsd mcp` helper's whole body until #185, relayed over its own
    /// `daemon.sock` connection. The daemon now serves it itself, so `relay` is a call
    /// inside the process.
    public static func relaying(token: String, managesAgents: Bool, movesItself: Bool,
                                transport: (any LineTransport)? = nil,
                                relay: @escaping Relay) -> AppService {
        @Sendable func send(_ method: String, _ request: some Encodable & Sendable,
                            fallback: String) async -> Outcome {
            let params: JSONValue
            do {
                params = try JSONValue.encoding(request)
            } catch {
                return .refused("That call could not be read, so nothing was done.")
            }
            switch await relay(method, params) {
            case .success(let result): return .shown(result["note"]?.stringValue ?? fallback)
            case .failure(let error): return .refused(error.message)
            }
        }

        return AppService(transport: transport, managesAgents: managesAgents,
                          movesItself: movesItself) { outcome, message, prompts, words in
            await send(DaemonAPI.Method.agentsFinishTurn,
                       DaemonAPI.FinishTurnRequest(token: token, outcome: outcome,
                                                   message: message, prompts: prompts,
                                                   waitingOn: words.waitingOn,
                                                   checkAgainInMinutes: words.checkAgainInMinutes,
                                                   wakeOn: words.wakeOn?.rawValue,
                                                   afterwards: words.afterwards?.rawValue,
                                                   addLabels: words.addLabels,
                                                   removeLabels: words.removeLabels,
                                                   move: words.move.map {
                                                       switch $0 {
                                                       case .move(let target, let removeLeft, let discardChanges):
                                                           DaemonAPI.MoveAsk(target: target, removeLeft: removeLeft,
                                                                             discardChanges: discardChanges)
                                                       }
                                                   }),
                       fallback: "Noted.")
        } showFile: { file in
            await send(DaemonAPI.Method.agentsShowFile,
                       DaemonAPI.ShowFileRequest(token: token, file: file),
                       fallback: "Open in the files pane.")
        } askForm: { title, questions in
            await send(DaemonAPI.Method.agentsAskForm,
                       DaemonAPI.AskFormRequest(token: token, title: title, questions: questions),
                       fallback: "Asked.")
        } workflows: { action, workflowID, content in
            await send(DaemonAPI.Method.agentsManageWorkflows,
                       DaemonAPI.ManageWorkflowsRequest(token: token, action: action,
                                                        workflowID: workflowID, content: content),
                       fallback: "Done.")
        } agents: { call in
            switch call {
            case .start(let prompt, let runtime, let model, let permissionMode, let worktree, let labels):
                return await send(DaemonAPI.Method.agentsStartHelper,
                                  DaemonAPI.StartHelperRequest(token: token, prompt: prompt,
                                                               runtime: runtime, model: model,
                                                               permissionMode: permissionMode,
                                                               worktree: worktree, labels: labels),
                                  fallback: "Started.")
            case .stop(let agentID):
                return await send(DaemonAPI.Method.agentsStopHelper,
                                  DaemonAPI.HelperRequest(token: token, agentID: agentID),
                                  fallback: "Stopped.")
            case .park(let agentID):
                return await send(DaemonAPI.Method.agentsParkHelper,
                                  DaemonAPI.HelperRequest(token: token, agentID: agentID),
                                  fallback: "Parked.")
            case .archive(let agentID):
                return await send(DaemonAPI.Method.agentsArchiveHelper,
                                  DaemonAPI.HelperRequest(token: token, agentID: agentID),
                                  fallback: "Archived.")
            case .list:
                return await send(DaemonAPI.Method.agentsListHelpers,
                                  DaemonAPI.ListHelpersRequest(token: token),
                                  fallback: "Nothing to list.")
            }
        } leases: { call in
            // A lease call may wait up to the daemon's limit before it answers (036).
            switch call {
            case .lease(let name, let minutes, let wait):
                return await send(DaemonAPI.Method.leasesLease,
                                  DaemonAPI.LeaseRequest(token: token, name: name,
                                                         minutes: minutes, wait: wait),
                                  fallback: "Leased.")
            case .release(let name):
                return await send(DaemonAPI.Method.leasesRelease,
                                  DaemonAPI.LeaseNameRequest(token: token, name: name),
                                  fallback: "Released.")
            case .list:
                return await send(DaemonAPI.Method.leasesList,
                                  DaemonAPI.LeaseTokenRequest(token: token),
                                  fallback: "Nothing to list.")
            }
        } events: { call in
            // A wait may be held up to the daemon's limit before it answers (042).
            switch call {
            case .wait(let action, let events, let filters, let from, let untilMinutes, let limit):
                return await send(DaemonAPI.Method.eventsWait,
                                  DaemonAPI.EventWaitRequest(token: token, action: action, events: events,
                                                             where: filters, from: from,
                                                             untilMinutes: untilMinutes, limit: limit),
                                  fallback: "Waiting.")
            case .cancel:
                return await send(DaemonAPI.Method.eventsCancel, DaemonAPI.EventTokenRequest(token: token),
                                  fallback: "Stopped waiting.")
            case .publish(let name, let message, let details):
                return await send(DaemonAPI.Method.eventsPublish,
                                  DaemonAPI.EventPublishRequest(token: token, name: name, message: message,
                                                                details: details),
                                  fallback: "Published.")
            }
        } sessions: { call in
            // Only ever the caller's own project: the daemon takes it from the token (065).
            switch call {
            case .list(let limit, let after):
                return await send(DaemonAPI.Method.agentsListSessions,
                                  DaemonAPI.ListSessionsRequest(token: token, limit: limit, after: after),
                                  fallback: "There are no sessions in this project.")
            case .read(let session):
                return await send(DaemonAPI.Method.agentsReadSession,
                                  DaemonAPI.ReadSessionRequest(token: token, session: session),
                                  fallback: SessionLookup.unavailable)
            }
        } itself: { call in
            // The agent's own session (#481): the daemon takes which from the token.
            switch call {
            case .afterTurn(let after):
                return await send(DaemonAPI.Method.agentsAfterTurn,
                                  DaemonAPI.AfterTurnRequest(token: token, afterwards: after.rawValue),
                                  fallback: "Noted.")
            case .labels(let add, let remove):
                return await send(DaemonAPI.Method.agentsSetOwnLabels,
                                  DaemonAPI.OwnLabelsRequest(token: token, add: add, remove: remove),
                                  fallback: "Labelled.")
            case .move(let move):
                let request: DaemonAPI.MoveSelfRequest
                switch move {
                case .move(let target, let removeLeft, let discardChanges)?:
                    request = .init(token: token, target: target, removeLeft: removeLeft,
                                    discardChanges: discardChanges)
                case nil:
                    request = .init(token: token, target: nil)
                }
                return await send(DaemonAPI.Method.agentsMoveSelf, request, fallback: "Noted.")
            case .waitOn(let agents, let wakeOn, let untilMinutes, let message):
                return await send(DaemonAPI.Method.agentsWaitOn,
                                  DaemonAPI.WaitOnRequest(token: token, agents: agents, wakeOn: wakeOn?.rawValue,
                                                          untilMinutes: untilMinutes, message: message),
                                  fallback: "Waiting.")
            }
        } pins: { call in
            // Always the caller's own project folder: the daemon takes it from the token (#159).
            switch call {
            case .pin(let arguments):
                return await send(DaemonAPI.Method.pinsPinPage,
                                  DaemonAPI.PinToolRequest(token: token, arguments: arguments), fallback: "Pinned.")
            case .unpin(let arguments):
                return await send(DaemonAPI.Method.pinsUnpinPage,
                                  DaemonAPI.PinToolRequest(token: token, arguments: arguments), fallback: "Unpinned.")
            case .movePin(let arguments):
                return await send(DaemonAPI.Method.pinsMovePin,
                                  DaemonAPI.PinToolRequest(token: token, arguments: arguments), fallback: "Moved.")
            case .pinSession(let arguments):
                return await send(DaemonAPI.Method.pinsPinSessionTool,
                                  DaemonAPI.PinToolRequest(token: token, arguments: arguments), fallback: "Pinned.")
            }
        } viewTool: { name, arguments in
            // The whole result back, not a note: the view is drawn from it (#187).
            let params: JSONValue
            do {
                params = try JSONValue.encoding(DaemonAPI.ViewToolCallRequest(token: token, name: name,
                                                                              arguments: arguments))
            } catch {
                return .failure("That call could not be read, so nothing was done.")
            }
            switch await relay(DaemonAPI.Method.viewsToolCall, params) {
            case .success(let result): return .success(result)
            case .failure(let error): return .failure(ViewToolFailure(error.message))
            }
        }
    }
}
