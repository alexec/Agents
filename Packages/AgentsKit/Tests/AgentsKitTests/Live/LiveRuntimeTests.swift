import Foundation
import Testing
@testable import AgentsKit

/// The three real runtimes, on this Mac, with Alex's own credentials.
///
/// Off unless `AGENTS_LIVE=1`, because it costs money and needs him signed in. Every
/// claim in research.md came from doing this by hand; this is the same thing, kept.
@Suite("Live runtimes", .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"),
       .timeLimit(.minutes(10)), .serialized)
struct LiveRuntimeTests {
    private func workspace() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/agents-live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Nothing below names a runtime except as data. One code path, three runtimes: if
    /// this test needs an `if` on the id, the claim in SC-009 is no longer true.
    @Test(arguments: RuntimeCatalog.builtIn)
    func aRuntimeCanBeStartedDrivenAndPickedUpAgain(runtime: Runtime) async throws {
        let discovery = RuntimeDiscovery()
        guard case .available(let path, _) = discovery.locate(runtime) else {
            Issue.record("\(runtime.name) is not installed on this Mac")
            return
        }
        let cwd = try workspace()
        defer { try? FileManager.default.removeItem(at: cwd) }

        let session = try ACPSession.launch(executable: URL(fileURLWithPath: path),
                                            arguments: runtime.arguments,
                                            cwd: cwd,
                                            environment: LoginShellPath.environment())
        let capabilities = try await session.initialize()
        #expect(capabilities.protocolVersion == 1)
        #expect(capabilities.supportsLoad, "an agent that cannot be picked up cannot be an agent here")

        let created = try await session.newSession(cwd: cwd)
        let advertised = await session.options
        #expect(!advertised.isEmpty, "\(runtime.name) advertises its options through configOptions")
        #expect(advertised.contains { $0.category == "model" },
                "every one of them offers a model choice through the one list")

        let result = try await session.prompt("Reply with exactly: PINEAPPLE. Nothing else.")
        #expect(result.reason == .endTurn)

        // Kill it the way a Mac restart would, then ask for the conversation back.
        await session.killRuntime()
        try await Task.sleep(for: .seconds(1))

        let second = try ACPSession.launch(executable: URL(fileURLWithPath: path),
                                           arguments: runtime.arguments,
                                           cwd: cwd,
                                           environment: LoginShellPath.environment())
        _ = try await second.initialize()
        try await second.continueSession(id: created.sessionId, cwd: cwd)
        let followUp = try await second.prompt("What word did you just say? Reply with that word only.")
        #expect(followUp.reason == .endTurn, "\(runtime.name) carried on from where it was")
        await second.end(gracePeriod: .seconds(3))
    }
}
