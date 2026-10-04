import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// Hands the daemon fake agents that do not start until the test lets each one.
///
/// What a test about how many runtimes start at once needs. A handshake that takes a
/// fixed stretch of real time is a race with the machine: on a busy one the first is
/// through before the second has even been launched, and "two together" reads as one
/// after the other. Held here, a runtime is still starting for as long as the test
/// says, however slow the machine.
///
/// Held by not letting a word reach the fake agent: the daemon's `initialize` waits in
/// the pipe, unanswered, until the launch's gate is opened.
final class HeldStartLauncher: SessionLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private let script: FakeACPAgent.Script
    private var gates: [TurnGate] = []
    private var agents: [FakeACPAgent] = []
    let keepsRuntimesWarm = false

    init(script: FakeACPAgent.Script = .init()) {
        self.script = script
    }

    func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
        let gate = TurnGate()
        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine,
                                 launch: RuntimeLaunchCatalog.launch(for: runtime.id),
                                 authMethodBeforeContinuing: ToolPolicyCatalog.policy(for: runtime.id).authMethodBeforeContinuing)
        let agent = FakeACPAgent(script: script, transport: HeldTransport(theirs, until: gate))
        // Kept, as `FakeLauncher` keeps its own: letting one go ends the other side.
        lock.withLock {
            gates.append(gate)
            agents.append(agent)
        }
        return session
    }

    /// How many runtimes have been launched, started or not.
    var launchCount: Int { lock.withLock { gates.count } }

    /// Let the runtime launched `index`th (from zero) start.
    func letStart(_ index: Int) {
        let gate: TurnGate? = lock.withLock { gates.indices.contains(index) ? gates[index] : nil }
        gate?.open()
    }

    /// Let every runtime launched so far start.
    func letAllStart() {
        for gate in lock.withLock({ gates }) { gate.open() }
    }
}

/// A transport whose reading side hears nothing until its gate opens, and then hears
/// everything that was said to it, in order.
private final class HeldTransport: LineTransport, @unchecked Sendable {
    private let inner: any LineTransport
    private let gate: TurnGate

    init(_ inner: any LineTransport, until gate: TurnGate) {
        self.inner = inner
        self.gate = gate
    }

    func write(line: String) throws { try inner.write(line: line) }

    func lines() -> AsyncThrowingStream<String, any Error> {
        let inner = self.inner, gate = self.gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                await gate.pass()
                do {
                    for try await line in inner.lines() { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func close() { inner.close() }
}
