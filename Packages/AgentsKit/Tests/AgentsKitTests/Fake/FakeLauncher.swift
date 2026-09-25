import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// Hands the daemon sessions wired to fake agents, so the whole daemon runs with no
/// CLI installed, no credentials and no network.
///
/// It holds every agent it makes: letting one go deallocates the other end of the
/// connection, and a session whose runtime has silently vanished waits for ever.
final class FakeLauncher: SessionLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [FakeACPAgent] = []
    private var scripts: [FakeACPAgent.Script]
    private var defaultScript: FakeACPAgent.Script
    private(set) var launches: [(runtime: String, cwd: URL, at: ContinuousClock.Instant)] = []
    /// What each launch was lent (043): `LentEnvironment.value` at the moment it started.
    private(set) var lent: [[String: String]] = []

    /// What the sessions it makes advertise. The capability flags decide what an agent
    /// asks of us, so a test that wants to be asked for a file turns them on here.
    private let capabilities: ACP.ClientCapabilities

    init(script: FakeACPAgent.Script = .init(), then scripts: [FakeACPAgent.Script] = [],
         capabilities: ACP.ClientCapabilities = .none) {
        self.defaultScript = script
        self.scripts = scripts
        self.capabilities = capabilities
    }

    func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
        lock.lock()
        let script = scripts.isEmpty ? defaultScript : scripts.removeFirst()
        launches.append((runtime.id, cwd, .now))
        lent.append(LentEnvironment.value)
        lock.unlock()

        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine, capabilities: capabilities)
        let agent = FakeACPAgent(script: script, transport: theirs)
        lock.lock()
        agents.append(agent)
        lock.unlock()
        return session
    }

    var launchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return launches.count
    }

    var lastAgent: FakeACPAgent? {
        lock.lock(); defer { lock.unlock() }
        return agents.last
    }

    /// The gaps between one launch and the next. What a test asserting runtimes are
    /// started one at a time reads: with a handshake that takes a known time, gaps
    /// shorter than it mean two were starting at once.
    var gapsBetweenLaunches: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return zip(launches.dropFirst(), launches).map { $0.at - $1.at }
    }

    var allAgents: [FakeACPAgent] {
        lock.lock(); defer { lock.unlock() }
        return agents
    }
}

extension RuntimeDiscovery {
    /// A discovery that finds everything, for tests that are not about discovery.
    static var findsEverything: RuntimeDiscovery {
        RuntimeDiscovery(searchPaths: ["/fake/bin"], fileExists: { _ in true })
    }
}
