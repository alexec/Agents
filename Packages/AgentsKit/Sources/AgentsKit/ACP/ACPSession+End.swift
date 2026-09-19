import Foundation

/// Lets a process's exit reach the session that was made after it.
final class ExitRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Int32) -> Void)?
    private var errorHandler: (@Sendable (String) -> Void)?

    func setHandlers(exit: @escaping @Sendable (Int32) -> Void, error: @escaping @Sendable (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handler = exit
        errorHandler = error
    }

    func exited(_ status: Int32) {
        lock.lock(); let h = handler; lock.unlock()
        h?(status)
    }

    func errored(_ text: String) {
        lock.lock(); let h = errorHandler; lock.unlock()
        h?(text)
    }
}

extension ACPSession {
    /// Start a runtime and hand back a session talking to it.
    public static func launch(executable: URL,
                              arguments: [String],
                              cwd: URL,
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ACPSession {
        let relay = ExitRelay()
        let process = try RuntimeProcess(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            onStandardError: { relay.errored($0) },
            onExit: { relay.exited($0) })
        let session = ACPSession(transport: process.transport, process: process)
        relay.setHandlers(
            exit: { status in Task { await session.noteExit(status: status) } },
            error: { text in Task { await session.note(standardError: text) } })
        return session
    }

    /// End an agent in the order the spec asks for: cancel a running turn, close the
    /// session, terminate, and only kill when that has not worked.
    ///
    /// Closing rather than killing matters because these runtimes persist their own
    /// sessions: an agent killed mid-sentence is one the runtime may not hand back
    /// cleanly, and handing it back is the whole of picking an agent up later.
    public func end(gracePeriod: Duration = .seconds(5)) async {
        await cancel()
        if let sessionID {
            _ = try? await callClose(sessionID: sessionID)
        }
        await closeConnection()
        guard let process = runtimeProcess else { return }
        process.terminate()

        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { process.kill() }
        process.cleanUp()
    }

    /// Whether the runtime is still there, which is not the same as whether the agent
    /// is working.
    public var isProcessRunning: Bool { runtimeProcess?.isRunning ?? false }

    public var processIdentifier: Int32? { runtimeProcess?.processIdentifier }

    /// Kill the runtime outright, the way a restart would. Here so that a test can
    /// prove a session comes back afterwards, which is the claim the whole pick-up
    /// story rests on.
    public func killRuntime() {
        runtimeProcess?.kill()
    }
}
