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
/// A failure here is news about someone else's software, not a bug in this one. The
/// tests are filled in by 023's US3; the helpers are here so the suite compiles.
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
}
