// The helper that owns the agents.
//
// Everything it does is in AgentsKit, so all of it is reachable from `swift test`.
// What is left here is starting up, and saying why if that does not work.
import AgentsKit
import Foundation

// A review control plane's demo host offers the echo runtime beside the others (T092).
if let demo = EchoAgent.runtime, CommandLine.arguments.count < 2 || CommandLine.arguments[1] != "acp-echo" {
    RuntimeCatalog.extra = [demo]
}

// `agentsd acp-echo`: the demo runtime App Review is given (058, T092), offered only on a
// host started with AGENTS_TEST_RUNTIME=echo. It answers every prompt by saying it back.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "acp-echo" {
    await EchoAgent.run()
    exit(0)
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

// The app's pinned toolsets (043, 048, 047), when this is the agentsd inside Agents.app:
// Contents/Helpers/agentsd beside Contents/Resources/toolsets/<runtime>/.
let toolsetsFolder: URL? = {
    let me = URL(filePath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    let folder = me.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/toolsets", isDirectory: true)
    return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
}()

let daemon: Daemon
do {
    let control: Daemon.Control? = if commandLine.controlNetwork {
        Daemon.Control(name: commandLine.hostName, code: commandLine.controlCode)
    } else {
        nil
    }
    // Every daemon on this Mac claims its runtime sessions in one shared folder, so a
    // scratch one never drives a conversation the real one holds (#228).
    daemon = try Daemon(serve: serve, control: control, toolsetsFolder: toolsetsFolder,
                        sessionLocks: Daemon.sharedSessionLocks,
                        allowOutsideRoot: CommandLine.arguments.contains(Daemon.allowOutsideRootFlag))
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
