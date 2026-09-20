import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Opt-in, against the real runtimes:
///
///     AGENTS_LIVE=1 AGENTS_MCP_HELPER=<path to agentsd> swift test --filter Live
///
/// The one question a fake cannot answer. Nothing in ACP or MCP makes a runtime call a
/// tool at the end of a turn, so whether an ending is ever accounted for comes down to
/// a description, a briefing line, and somebody else's model. `SuggestedPromptLiveTests`
/// found the hard version of this: offered a tool and nothing else, three runtimes
/// called it exactly never, and one line in the prompt changed that. This is the same
/// question asked of the fourth tool.
///
/// SC-007 wants 90% of normal endings carrying a report. That is a number only a run
/// like this can produce, and a runtime that will not call the tool is a finding to
/// write down — in `research.md`, per T062 — rather than a failure of the design. The
/// app is honest about a silent ending either way; that is what Phase 5 is for.
///
/// A failure here is news about someone else's software, not a bug in this one.
// Serialised: three runtimes at once is three models and three sets of output
// interleaved, which is a report nobody can read.
@Suite("Live: whether a runtime says how it went", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"
                && ProcessInfo.processInfo.environment["AGENTS_MCP_HELPER"] != nil),
       .timeLimit(.minutes(10)))
struct OutcomeReportLiveTests {
    /// A daemon of its own, on its own socket, so this never touches the real one.
    private func daemon() throws -> (Daemon, StoreLocations, URL) {
        // Short on purpose. A Unix socket path is 103 characters and the usual
        // temporary directory spends most of them before we start.
        let root = URL(filePath: "/tmp").appending(path: "ag-\(UUID().uuidString.prefix(8))")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "print('hello')\n".write(to: work.appending(path: "hello.py"),
                                     atomically: true, encoding: .utf8)
        let locations = StoreLocations(root: root)
        return (try Daemon(locations: locations), locations, work.resolvingSymlinksInPath())
    }

    /// Runs one turn and reports what the agent ended up saying about it, if anything.
    ///
    /// Waits past the first ending, because 014's second half is a turn of its own: an
    /// agent that said nothing is asked once, and what it says to *that* is as much the
    /// finding as what it said the first time.
    private func run(_ runtimeID: String, asking prompt: String) async throws -> Agent? {
        let (daemon, _, work) = try daemon()
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }
        let core = daemon.daemonCore

        let id = try await core.start(.init(runtimeID: runtimeID, cwd: work, prompt: prompt))

        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline {
            // Copilot asks before it runs anything and there is no window here to ask.
            // A run that stalls on an unanswered question says nothing about the tool,
            // so this stands in for the person.
            for pending in await core.pendingPermissionRequests() {
                guard let allow = pending.options.first(where: { $0.kind.allows }) else { continue }
                try? await core.answerPermission(.init(permissionID: pending.id,
                                                       optionID: allow.optionID))
            }
            if let agent = await core.agent(id), !agent.state.hasTurnInFlight,
               agent.queuedPrompts.isEmpty,
               // Either it said something, or it was asked and the asked turn is over.
               agent.report != nil || agent.outcomeAsked {
                // A beat, so the asked turn has begun before this reads "settled".
                try await Task.sleep(for: .seconds(2))
                if let settled = await core.agent(id), !settled.state.hasTurnInFlight,
                   settled.queuedPrompts.isEmpty {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        // Printed because a live run is a report: a runtime that was never signed in
        // must not read as a runtime that declined to say how it went.
        let agent = await core.agent(id)
        print("== \(runtimeID)")
        print("   state: \(String(describing: agent?.state))")
        print("   ended: \(String(describing: agent?.endedReason))")
        print("   asked: \(agent?.outcomeAsked == true ? "yes" : "no")")
        if let report = agent?.report {
            print("   outcome: \(report.outcome.rawValue) — \(report.message)")
        } else {
            print("   outcome: none. This ending is unaccounted for.")
        }
        if let report = agent?.report {
            // Whatever it said, it has to be usable: a message a person can read on a
            // row without opening anything.
            #expect(!report.message.isEmpty)
            #expect(report.message.count <= WorkReport.messageLimit)
        }
        return agent
    }

    private func installed(_ runtimeID: String) -> Bool {
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else { return false }
        if case .available = RuntimeDiscovery().locate(runtime) { return true }
        Issue.record("\(runtimeID) is not installed")
        return false
    }

    /// The whole chain, end to end: the fourth tool is attached, the helper is started
    /// by the runtime, the call comes back down our socket, and the outcome lands on
    /// the agent. Asked for outright, so this is about the plumbing rather than about
    /// whether a model felt like it.
    @Test(arguments: ["claude", "grok"])
    func aRuntimeToldToUseTheToolUsesIt(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        let agent = try await run(runtimeID, asking: """
            Read hello.py. Then call the report_outcome tool with outcome "done" and a \
            one-sentence message saying what is in it.
            """)
        #expect(agent?.report?.outcome == .done)
    }

    /// The one that matters, and the only check in this feature that can fail for
    /// reasons no unit test sees.
    ///
    /// A job with a question in it that the agent cannot answer for itself. The right
    /// ending is `needs_answer` with the question as the message — not the question
    /// buried at the bottom of a reply, which is the exact failure the feature exists
    /// to remove. Nothing here mentions the tool: the briefing's own line is what does.
    @Test(arguments: ["claude", "copilot", "grok"])
    func anUnanswerableQuestionEndsAsNeedsAnswerRatherThanBuriedInAReply(
        runtimeID: String
    ) async throws {
        guard installed(runtimeID) else { return }
        let agent = try await run(runtimeID, asking: """
            Add a greet(name) function to hello.py. It should greet in either English \
            or French and I have not told you which, and I do not want you to guess or \
            to support both. Do not run anything.
            """)
        // Not asserted, because a model that says nothing is allowed to and the run is
        // the finding. What is worth knowing is printed above, and written down in
        // research.md against SC-007's 90%.
        if let outcome = agent?.report?.outcome {
            print("   → \(runtimeID) ended as \(outcome.rawValue)")
        }
    }
}
