import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Whether each real runtime picks its conversation back up in a different folder (053).
///
/// A move changes the folder an agent's next runtime is started in, and asks that runtime
/// to continue the session it had. Claude's CLI does, checked by hand on 2026-09-25. Grok
/// and Cursor file their sessions by folder, so they might answer "not found", or carry on
/// having forgotten everything. This is the measurement research R2 and R3 wait on.
///
/// Off unless `AGENTS_LIVE=1`: it costs money and needs Alex signed in.
@Suite("Live: moving folders", .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"),
       .timeLimit(.minutes(10)), .serialized)
struct RuntimeMoveLiveTests {
    /// A git repository in a folder of its own, since a move is always between two.
    private func repository(_ label: String) async throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/agents-move-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await GitProcess(["init", "-q"], in: url).run()
        return url
    }

    @Test(arguments: RuntimeCatalog.builtIn)
    func aRuntimeRemembersItsConversationInAnotherFolder(runtime: Runtime) async throws {
        // Codex, Gemini and Antigravity are only ever the app's own copies, in the real
        // app's tools folder. Only launched from there; nothing is written to it.
        var discovery = RuntimeDiscovery()
        discovery.macToolsHome = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Agents/tools").path
        guard case .available(let path, _) = discovery.locate(runtime) else {
            print("== \(runtime.id): not installed, not measured")
            return
        }
        let first = try await repository("a")
        let second = try await repository("b")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let before = try ACPSession.launch(executable: URL(filePath: path), arguments: runtime.arguments,
                                           cwd: first, environment: LoginShellPath.environment())
        _ = try await before.initialize()
        let created = try await before.newSession(cwd: first)
        _ = try await before.prompt("Remember the word PELICAN. Reply only OK.")
        await before.end(gracePeriod: .seconds(3))
        try await Task.sleep(for: .seconds(1))

        let after = try ACPSession.launch(executable: URL(filePath: path), arguments: runtime.arguments,
                                          cwd: second, environment: LoginShellPath.environment())
        let said = Spoken()
        let events = after.eventStream()
        let watching = Task {
            for await event in events {
                if case .entry(.agentMessage(_, let text, _)) = event { said.add(text) }
            }
        }
        defer { watching.cancel() }
        _ = try await after.initialize()

        var resumed = true
        do {
            try await after.continueSession(id: created.sessionId, cwd: second)
        } catch {
            resumed = false
            print("== \(runtime.id): refused to continue in another folder: \(error)")
        }
        var remembered = false
        if resumed {
            // Whatever a load replayed is not the answer: only what comes after the question.
            let replayed = said.text.count
            _ = try await after.prompt("What word did I ask you to remember? One word.")
            remembered = String(said.text.dropFirst(replayed)).uppercased().contains("PELICAN")
        }
        await after.end(gracePeriod: .seconds(3))

        let line = "\(runtime.id): continued=\(resumed) remembered=\(remembered)"
        print("== " + line)
        let log = URL(filePath: "/tmp/053-move-live.txt")
        let previous = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        try? (previous + line + "\n").write(to: log, atomically: true, encoding: .utf8)
        #expect(resumed && remembered, "\(runtime.name) carries its conversation into another folder")
    }
}
