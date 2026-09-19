import Foundation
import Testing
@testable import AgentsKit

/// The four real runtimes, on this Mac, with Alex's own credentials.
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

    /// Nothing below names a runtime except as data. One code path, four runtimes: if
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
        // Options are a thing a runtime may offer, not a thing every runtime has. Three
        // of them send `configOptions` and Cursor sends none at all: it puts its models
        // and modes on the `session/new` result, which we do not decode for anyone,
        // because those shapes disagree between runtimes and are leaving the protocol.
        // What has to hold is that a runtime offering options offers usable ones.
        let advertised = await session.options
        if !advertised.isEmpty {
            #expect(advertised.contains { $0.category == "model" },
                    "\(runtime.name) offers options, so one of them is the model choice")
            #expect(advertised.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty },
                    "\(runtime.name) offers nothing the start sheet cannot draw")
        }

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
