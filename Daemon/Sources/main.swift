// The helper that owns the agents.
//
// Everything it does is in AgentsKit, so all of it is reachable from `swift test`.
// What is left here is starting up, and saying why if that does not work.
import AgentsKit
import Foundation

// Run as `agentsd mcp <token>` this is not the daemon at all: it is the MCP server the
// daemon hands to every agent, started by the runtime the way it starts any stdio MCP
// server. One binary rather than two, so there is one thing to build, sign and ship.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "mcp" {
    let token = CommandLine.arguments[2]
    // An agent another agent started is not offered the tools for starting, stopping
    // or archiving agents (028). The daemon says so here, when it hands the runtime
    // this server; it refuses the calls as well, so this only keeps the menu honest.
    let managesAgents = !CommandLine.arguments.dropFirst(3).contains(DaemonCore.noAgentToolsFlag)
    // The daemon that started this said where it is. Anything else would be a guess.
    let client = DaemonClient(locations: .default)
    // Every tool does the same thing with what it is given: hand it to the daemon
    // and repeat what the daemon says back to the agent. Nothing is decided here.
    @Sendable func relay(_ method: String, _ request: some Encodable & Sendable,
                         fallback: String) async -> AppService.Outcome {
        do {
            // Never started here. If no daemon is answering there is no window to show
            // anything in, and starting one from inside a runtime's own child process
            // is not this program's business.
            try await client.connect(startIfNeeded: false)
            let result = try await client.call(method, request)
            // Let go straight away. The daemon shuts down when nothing is in hand and
            // nobody is connected, and a helper holding a socket open for a runtime
            // that has gone quiet would be a window that is not there.
            await client.disconnect()
            return .shown(result["note"]?.stringValue ?? fallback)
        } catch let error as JSONRPCError {
            return .refused(error.message)
        } catch {
            return .refused("The app is not running, so nothing was shown.")
        }
    }

    let service = AppService(transport: FDTransport(readFD: 0, writeFD: 1),
                             managesAgents: managesAgents,
                             finishTurn: { outcome, message, prompts, title, words in
        await relay(DaemonAPI.Method.agentsFinishTurn,
                    DaemonAPI.FinishTurnRequest(token: token, outcome: outcome,
                                                message: message, prompts: prompts,
                                                title: title, waitingOn: words.waitingOn,
                                                checkAgainInMinutes: words.checkAgainInMinutes),
                    fallback: "Noted.")
    }) { prompts in
        await relay(DaemonAPI.Method.agentsSuggestPrompts,
                    DaemonAPI.SuggestPromptsRequest(token: token, prompts: prompts),
                    fallback: "Shown in the person's empty prompt.")
    } showFile: { file in
        await relay(DaemonAPI.Method.agentsShowFile,
                    DaemonAPI.ShowFileRequest(token: token, file: file),
                    fallback: "Open in the files pane.")
    } workflows: { action, workflowID, content in
        await relay(DaemonAPI.Method.agentsManageWorkflows,
                    DaemonAPI.ManageWorkflowsRequest(token: token, action: action,
                                                     workflowID: workflowID, content: content),
                    fallback: "Done.")
    } reportOutcome: { outcome, message, words in
        await relay(DaemonAPI.Method.agentsReportOutcome,
                    DaemonAPI.ReportOutcomeRequest(token: token, outcome: outcome,
                                                   message: message, waitingOn: words.waitingOn,
                                                   checkAgainInMinutes: words.checkAgainInMinutes),
                    fallback: "Noted.")
    } agents: { call in
        switch call {
        case .start(let prompt, let runtime, let model, let permissionMode, let worktree):
            return await relay(DaemonAPI.Method.agentsStartHelper,
                               DaemonAPI.StartHelperRequest(token: token, prompt: prompt,
                                                            runtime: runtime, model: model,
                                                            permissionMode: permissionMode,
                                                            worktree: worktree),
                               fallback: "Started.")
        case .stop(let agentID):
            return await relay(DaemonAPI.Method.agentsStopHelper,
                               DaemonAPI.HelperRequest(token: token, agentID: agentID),
                               fallback: "Stopped.")
        case .archive(let agentID):
            return await relay(DaemonAPI.Method.agentsArchiveHelper,
                               DaemonAPI.HelperRequest(token: token, agentID: agentID),
                               fallback: "Archived.")
        case .list:
            return await relay(DaemonAPI.Method.agentsListHelpers,
                               DaemonAPI.ListHelpersRequest(token: token),
                               fallback: "Nothing to list.")
        }
    } pullRequests: { call in
        // Only ever the caller's own pull request: the daemon takes which one, and
        // where it goes, from the run the caller was started for (038 R7).
        switch call {
        case .push:
            return await relay(DaemonAPI.Method.agentsPushPullRequest,
                               DaemonAPI.PushPullRequestRequest(token: token),
                               fallback: "Pushed.")
        case .reply(let body, let inReplyTo):
            return await relay(DaemonAPI.Method.agentsReplyOnPullRequest,
                               DaemonAPI.ReplyOnPullRequestRequest(token: token, body: body,
                                                                   inReplyTo: inReplyTo),
                               fallback: "Replied.")
        }
    } leases: { call in
        // A lease call may wait up to the daemon's limit before it answers (036). The
        // socket read has no timeout of its own, so the daemon's is the only one.
        switch call {
        case .lease(let name, let minutes, let wait):
            return await relay(DaemonAPI.Method.leasesLease,
                               DaemonAPI.LeaseRequest(token: token, name: name,
                                                      minutes: minutes, wait: wait),
                               fallback: "Leased.")
        case .release(let name):
            return await relay(DaemonAPI.Method.leasesRelease,
                               DaemonAPI.LeaseNameRequest(token: token, name: name),
                               fallback: "Released.")
        case .list:
            return await relay(DaemonAPI.Method.leasesList,
                               DaemonAPI.LeaseTokenRequest(token: token),
                               fallback: "Nothing to list.")
        }
    }
    let task = Task {
        await service.run()
        exit(0)
    }
    withExtendedLifetime(task) {
        dispatchMain()
    }
}

let commandLine = DaemonCommandLine(CommandLine.arguments)
guard case .daemon(let serve, let detach) = commandLine.mode else { exit(2) }

// `--detach` (037): a server's daemon is started by an ssh command that should finish
// at once. Start a copy of this process in a session of its own, told everything but
// `--detach`, and leave. A daemon already holding the lock means there is nothing to
// start, and the copy would only find that out and exit.
if detach {
    let locations = StoreLocations.default
    do {
        try locations.createDirectories()
        guard let probe = DaemonLock(at: locations.lock) else { exit(0) }
        probe.release()
        let me = URL(filePath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        try Spawn.detached(executable: me, arguments: commandLine.childArguments,
                           environment: ProcessInfo.processInfo.environment, log: locations.log)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("agentsd could not detach: \(error)\n".utf8))
        exit(1)
    }
}

let daemon: Daemon
do {
    daemon = try Daemon(serve: serve)
} catch Daemon.StartError.alreadyRunning {
    // Another daemon holds the lock. That is the ordinary case when two windows open
    // at once, and there is nothing to say about it.
    exit(0)
} catch {
    FileHandle.standardError.write(Data("agentsd could not start: \(error)\n".utf8))
    exit(1)
}

let task = Task {
    do {
        try await daemon.start()
    } catch {
        FileHandle.standardError.write(Data("agentsd could not listen: \(error)\n".utf8))
        exit(1)
    }
    await daemon.run()
    exit(0)
}

// Keep the process alive while that task runs.
withExtendedLifetime(task) {
    dispatchMain()
}
