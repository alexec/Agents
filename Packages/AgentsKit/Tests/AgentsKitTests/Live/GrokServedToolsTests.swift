import Foundation
import Testing
@testable import AgentsKit

/// Opt-in, against the real runtimes: `AGENTS_LIVE=1 swift test --filter Live`.
///
/// This one exists because of the single finding that decided User Story 8. With the
/// file and terminal capabilities off, Grok does its own file IO and we see nothing;
/// with them on, every read and write comes through us. It is a claim about somebody
/// else's software, so it is worth re-running when Grok updates.
@Suite("Live: what a runtime does with our capabilities",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"),
       .timeLimit(.minutes(5)))
struct GrokServedToolsTests {
    private func workspace() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: "AgentsLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original line\n".write(to: root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        return root.resolvingSymlinksInPath()
    }

    private func launch(_ runtime: Runtime, cwd: URL,
                        capabilities: ACP.ClientCapabilities) throws -> ACPSession {
        let discovery = RuntimeDiscovery()
        guard case .available(let path, _) = discovery.locate(runtime) else {
            Issue.record("\(runtime.name) is not installed")
            throw CancellationError()
        }
        return try ACPSession.launch(executable: URL(filePath: path),
                                     arguments: runtime.arguments,
                                     cwd: cwd,
                                     environment: LoginShellPath.environment(),
                                     capabilities: capabilities)
    }

    @Test func grokRoutesItsFileWorkThroughUsOnceWeSayItCan() async throws {
        let work = try workspace()
        let session = try launch(RuntimeCatalog.grok, cwd: work, capabilities: .app)
        await session.serve(scope: FolderScope(folders: [work]), terminals: nil)

        let served = Served()
        let events = session.eventStream()
        let watching = Task {
            for await event in events {
                if case .served(let request) = event { served.add(request) }
            }
        }
        defer { watching.cancel() }

        _ = try await session.initialize()
        _ = try await session.newSession(cwd: work)
        _ = try await session.prompt("Change the word 'original' to 'edited' in notes.txt. Nothing else.")
        await session.end()

        // What we advertised is what it used.
        #expect(served.requests.contains { if case .readFile = $0.kind { return true } else { return false } },
                "Grok read through the client")
    }

    @Test func everyRuntimeStillStartsWithEverythingAdvertised() async throws {
        // The flags are a promise. If one of them makes a runtime refuse to start, this
        // is where it shows up rather than in somebody's window.
        for runtime in RuntimeCatalog.builtIn {
            let work = try workspace()
            let session = try launch(runtime, cwd: work, capabilities: .app)
            let handshake = try await session.initialize()
            #expect(handshake.speaksOurVersion, "\(runtime.name) answered another version")
            let result = try await session.newSession(cwd: work)
            #expect(!result.sessionId.isEmpty, "\(runtime.name) would not start a session")
            await session.end()
        }
    }
}

/// What the client was asked to do, collected across the actor boundary.
final class Served: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [ServedRequest] = []

    func add(_ request: ServedRequest) {
        lock.lock(); defer { lock.unlock() }
        collected.append(request)
    }

    var requests: [ServedRequest] {
        lock.lock(); defer { lock.unlock() }
        return collected
    }
}
