import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Opt-in, against the real runtimes:
///
///     AGENTS_LIVE=1 AGENTS_MCP_HELPER=<path to agentsd> swift test --filter FinishTurnLiveTests
///
/// The one question a fake cannot answer: whether a runtime, told once in the
/// briefing, ends its turns with the one call. `OutcomeReportLiveTests` asked it of
/// `report_outcome`; this asks it of `finish_turn`, and SC-004 is the comparison —
/// the share of normal endings that are accounted for must not fall.
///
/// A failure here is news about someone else's software, not a bug in this one.
@Suite("Live: whether a runtime ends its turns", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_LIVE"] == "1"
                && ProcessInfo.processInfo.environment["AGENTS_MCP_HELPER"] != nil),
       .timeLimit(.minutes(10)))
struct FinishTurnLiveTests {
    /// A daemon of its own, on its own socket, so this never touches the real one.
    func daemon() throws -> (Daemon, StoreLocations, URL) {
        let root = URL(filePath: "/tmp").appending(path: "ag-\(UUID().uuidString.prefix(8))")
        let work = root.appending(path: "work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "print('hello')\n".write(to: work.appending(path: "hello.py"),
                                     atomically: true, encoding: .utf8)
        let locations = StoreLocations(root: root)
        return (try Daemon(locations: locations), locations, work.resolvingSymlinksInPath())
    }

    func installed(_ runtimeID: String) -> Bool {
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else { return false }
        if case .available = RuntimeDiscovery().locate(runtime) { return true }
        Issue.record("\(runtimeID) is not installed")
        return false
    }

    /// Runs one turn and reports what the agent ended up saying about it, if anything.
    ///
    /// Waits past the first ending, as `OutcomeReportLiveTests` does: an agent that
    /// said nothing is asked once, and what it says to that is as much the finding as
    /// what it said the first time.
    private func run(_ runtimeID: String, asking prompt: String) async throws -> Agent? {
        let (daemon, _, work) = try daemon()
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }
        let core = daemon.daemonCore

        let id = try await core.start(.init(runtimeID: runtimeID, cwd: work, prompt: prompt))

        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        while ContinuousClock.now < deadline {
            // Copilot asks before it runs anything and there is no window here to ask.
            for pending in await core.pendingPermissionRequests() {
                guard let allow = pending.options.first(where: { $0.kind.allows }) else { continue }
                try? await core.answerPermission(.init(permissionID: pending.id,
                                                       optionID: allow.optionID))
            }
            if let agent = await core.agent(id), !agent.state.hasTurnInFlight,
               agent.queuedPrompts.isEmpty,
               agent.report != nil || agent.outcomeAsked {
                try await Task.sleep(for: .seconds(2))
                if let settled = await core.agent(id), !settled.state.hasTurnInFlight,
                   settled.queuedPrompts.isEmpty {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        // Printed because a live run is a report, in the shape 014's R11 table reads:
        // one line per runtime, with what it said and how many chips came with it.
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
        print("   chips: \(agent?.suggestedPrompts.count ?? 0)")
        if let report = agent?.report {
            #expect(!report.message.isEmpty)
            #expect(report.message.count <= WorkReport.messageLimit)
        }
        return agent
    }

    /// The whole chain, end to end: the tool is attached, the helper is started by
    /// the runtime, the call comes back down our socket, and both halves land. Asked
    /// for outright, so this is about the plumbing rather than whether a model felt
    /// like it.
    @Test(arguments: ["claude", "grok"])
    func askedOutrightItCallsIt(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        let agent = try await run(runtimeID, asking: """
            Read hello.py. Then call the finish_turn tool with outcome "done", a \
            one-sentence message saying what is in it, and two next prompts.
            """)
        #expect(agent?.report?.outcome == .done)
        #expect(agent?.suggestedPrompts.isEmpty == false)
    }

    /// The one that matters: nothing here mentions the tool. The briefing's one line
    /// is what does, and SC-004 is whether the turn is accounted for as often as it
    /// was when the briefing had two lines. Never failed on a runtime that will not
    /// call it — that is a finding for research.md R10, not a bug in this software.
    @Test(arguments: ["claude", "copilot", "grok"])
    func fromTheBriefingAloneDoesItEndTheTurn(runtimeID: String) async throws {
        guard installed(runtimeID) else { return }
        let agent = try await run(runtimeID, asking: """
            Add a greet(name) function to hello.py that prints a greeting. Do not run \
            anything.
            """)
        if let outcome = agent?.report?.outcome {
            print("   → \(runtimeID) ended as \(outcome.rawValue) with \(agent?.suggestedPrompts.count ?? 0) chips")
        } else {
            print("   → \(runtimeID) did not end its turn with the call")
        }
    }
}
