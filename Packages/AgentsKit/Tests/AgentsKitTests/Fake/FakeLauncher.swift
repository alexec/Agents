import Foundation
@testable import AgentsKit

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
    private(set) var launches: [(runtime: String, cwd: URL)] = []

    init(script: FakeACPAgent.Script = .init(), then scripts: [FakeACPAgent.Script] = []) {
        self.defaultScript = script
        self.scripts = scripts
    }

    func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
        lock.lock()
        let script = scripts.isEmpty ? defaultScript : scripts.removeFirst()
        launches.append((runtime.id, cwd))
        lock.unlock()

        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine)
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
