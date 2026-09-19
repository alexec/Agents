import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Opt-in, against the real runtimes:
///
///     AGENTS_LIVE=1 AGENTS_MCP_HELPER=<path to agentsd> swift test --filter Live
///
/// The one question a fake cannot answer: nothing in ACP or MCP makes a runtime call a
/// tool, so whether the row of suggestions ever appears comes down to a description
/// and somebody else's model. This runs a real daemon, with a real runtime, which
/// starts the real helper.
///
/// What the runs so far say:
///
/// - **Claude adapter** takes the tool when asked for it, as `mcp__agents__suggest_next_prompts`.
/// - **Grok** takes it too, as `agents__suggest_next_prompts`, through its own `use_tool`.
/// - **Copilot** has a follow-up feature of its own and uses that instead: a tool call
///   titled "Suggesting follow-up prompts" carrying one sentence of prose in
///   `rawInput.prompt`. Asked outright for ours, it still reached for theirs. So
///   Copilot is not asserted on here; a run that shows it calling ours would be news.
///
/// A failure here is news about someone else's software, not a bug in this one.
// Serialised: three runtimes at once is three models and three sets of output
// interleaved, which is a report nobody can read.
@Suite("Live: whether a runtime suggests anything", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"
                && ProcessInfo.processInfo.environment["AGENTS_MCP_HELPER"] != nil),
       .timeLimit(.minutes(10)))
struct SuggestedPromptLiveTests {
    /// A daemon of its own, on its own socket, so this never touches the real one.
    private func daemon() throws -> (Daemon, StoreLocations, URL) {
        // Short on purpose. A Unix socket path is 103 characters and the usual
        // temporary directory spends most of them before we start.
        let root = URL(filePath: "/tmp").appending(path: "ag-\(UUID().uuidString.prefix(8))")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "print('hello')\n".write(to: work.appending(path: "hello.py"), atomically: true, encoding: .utf8)
        let locations = StoreLocations(root: root)
        return (try Daemon(locations: locations), locations, work.resolvingSymlinksInPath())
    }

    private func run(_ runtimeID: String, asking prompt: String) async throws -> [SuggestedPrompt] {
        let (daemon, _, work) = try daemon()
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }
        let core = daemon.daemonCore

        let id = try await core.start(.init(runtimeID: runtimeID, cwd: work, prompt: prompt))

        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while ContinuousClock.now < deadline {
            // Copilot asks before it runs anything and there is no window here to ask.
            // A run that stalls on an unanswered question says nothing about the tool,
            // so this stands in for the person.
            for pending in await core.pendingPermissionRequests() {
                guard let allow = pending.options.first(where: { $0.kind.allows }) else { continue }
                try? await core.answerPermission(.init(permissionID: pending.id, optionID: allow.optionID))
            }
            if await core.agent(id)?.state.hasTurnInFlight == false { break }
            try await Task.sleep(for: .milliseconds(500))
        }

        // Printed because a live run is a report: a runtime that was never signed in
        // must not read as a runtime that declined to suggest anything.
        print("   state: \(String(describing: await core.agent(id)?.state))")
        let suggested = await core.agent(id)?.suggestedPrompts ?? []
        print("== \(runtimeID) suggested \(suggested.count):")
        for prompt in suggested { print("   [\(prompt.label)] \(prompt.prompt)") }
        for prompt in suggested {
            #expect(!prompt.label.isEmpty)
            #expect(!prompt.prompt.isEmpty)
            #expect(prompt.label.count <= SuggestedPrompt.labelLimit)
        }
        #expect(suggested.count <= SuggestedPrompt.limit)
        return suggested
    }

    private func installed(_ runtimeID: String) -> Bool {
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else { return false }
        if case .available = RuntimeDiscovery().locate(runtime) { return true }
        Issue.record("\(runtimeID) is not installed")
        return false
    }

    /// The whole chain, end to end: the server is attached, the helper is started by
    /// the runtime, the call comes back down our socket, and the words land on the
    /// agent. Asked for outright, so this is about the plumbing rather than about
    /// whether a model felt like it.
    @Test(arguments: ["claude", "grok"])
    func aRuntimeToldToUseTheToolUsesIt(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        let suggested = try await run(runtimeID, asking: """
            Read hello.py. Then call the suggest_next_prompts tool with two things I \
            might want to ask you next about this file.
            """)
        #expect(!suggested.isEmpty)
    }

    /// Whether it happens unasked, which is the thing the feature is for. Not an
    /// assertion: a model that says nothing is allowed to, and the run is the finding.
    @Test(arguments: ["claude", "copilot", "grok"])
    func whatARuntimeDoesWithTheToolUnprompted(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        // A job with an obvious next step left in it, because that is when the tool is
        // meant to fire. Asking a runtime to summarise a one-line file and then
        // counting the suggestions would be measuring the wrong thing. Nothing here
        // mentions the tool: the daemon's own line is what does that.
        _ = try await run(runtimeID, asking: """
            Add a greet(name) function to hello.py that returns a greeting. Do not \
            write a test for it and do not run anything.
            """)
    }
}
