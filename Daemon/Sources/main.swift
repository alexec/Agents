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
    // The daemon that started this said where it is. Anything else would be a guess.
    let client = DaemonClient(locations: DaemonCore.helperLocations)
    let service = SuggestionService(transport: FDTransport(readFD: 0, writeFD: 1)) { prompts in
        do {
            // Never started here. If no daemon is answering there is no window to show
            // a suggestion in, and starting one from inside a runtime's own child
            // process is not this program's business.
            try await client.connect(startIfNeeded: false)
            let result = try await client.call(DaemonAPI.Method.agentsSuggestPrompts,
                                               DaemonAPI.SuggestPromptsRequest(token: token,
                                                                               prompts: prompts))
            // Let go straight away. The daemon shuts down when nothing is in hand and
            // nobody is connected, and a helper holding a socket open for a runtime
            // that has gone quiet would be a window that is not there.
            await client.disconnect()
            return .shown(result["note"]?.stringValue ?? "Shown above the prompt.")
        } catch let error as JSONRPCError {
            return .refused(error.message)
        } catch {
            return .refused("The app is not running, so nothing was shown.")
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

let daemon: Daemon
do {
    daemon = try Daemon()
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
