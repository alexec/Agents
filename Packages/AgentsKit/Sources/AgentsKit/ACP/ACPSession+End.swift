import Foundation

/// Lets a process's exit reach the session that was made after it.
///
/// The process is running before the session exists, so it can say something on stderr
/// and die in that moment: a runtime that refuses to start does exactly that, and a
/// loaded machine widens the moment. What arrives before the handlers is kept and handed
/// to them when they come, rather than dropped, which left the session's event stream
/// open for good (#225).
final class ExitRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Int32) -> Void)?
    private var errorHandler: (@Sendable (String) -> Void)?
    private var earlyExit: Int32?
    private var earlyErrors: [String] = []

    func setHandlers(exit: @escaping @Sendable (Int32) -> Void, error: @escaping @Sendable (String) -> Void) {
        lock.lock()
        handler = exit
        errorHandler = error
        let errors = earlyErrors, status = earlyExit
        earlyErrors = []
        earlyExit = nil
        lock.unlock()
        for text in errors { error(text) }
        if let status { exit(status) }
    }

    func exited(_ status: Int32) {
        lock.lock()
        guard let h = handler else { earlyExit = status; lock.unlock(); return }
        lock.unlock()
        h(status)
    }

    func errored(_ text: String) {
        lock.lock()
        guard let h = errorHandler else { earlyErrors.append(text); lock.unlock(); return }
        lock.unlock()
        h(text)
    }
}

extension ACPSession {
    /// Start a runtime and hand back a session talking to it.
    public static func launch(executable: URL,
                              arguments: [String],
                              cwd: URL,
                              environment: [String: String] = RuntimeEnvironment.forRuntimes(),
                              capabilities: ACP.ClientCapabilities = .none,
                              launch: RuntimeLaunch? = nil,
                              authMethodBeforeContinuing: String? = nil) throws -> ACPSession {
        let relay = ExitRelay()
        let process = try RuntimeProcess(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            onStandardError: { relay.errored($0) },
            onExit: { relay.exited($0) })
        let session = ACPSession(transport: process.transport, process: process, program: executable,
                                 capabilities: capabilities, launch: launch,
                                 authMethodBeforeContinuing: authMethodBeforeContinuing)
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
            // Asked, and waited on for no longer than the grace period. A runtime that
            // never answers would otherwise hold this here for good — and with it a
            // stop, the queue draining behind a turn, and the daemon's own shutdown.
            // Closing the connection below fails the call if it is still outstanding.
            let answered = Flag()
            Task { _ = try? await self.callClose(sessionID: sessionID); answered.set() }
            let deadline = ContinuousClock.now.advanced(by: gracePeriod)
            while !answered.isSet, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
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

    public var processIdentifier: Int32? { runtimeProcess?.processIdentifier }

    /// Kill the runtime outright, the way a restart would. Here so that a test can
    /// prove a session comes back afterwards, which is the claim the whole pick-up
    /// story rests on.
    public func killRuntime() {
        runtimeProcess?.kill()
    }
}

/// Set once, read from anywhere.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
