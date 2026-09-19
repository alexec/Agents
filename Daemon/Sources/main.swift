// The helper that owns the agents.
//
// Everything it does is in AgentsKit, so all of it is reachable from `swift test`.
// What is left here is starting up, and saying why if that does not work.
import AgentsKit
import Foundation

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
