import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a sandboxed window asks of a host instead of doing it itself (058, T045, T046).
@Suite("A host does the window's disk and Finder work")
struct MacHostMethodsTests {
    private func core() throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMacHost-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        return (DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                           launcher: FakeLauncher()), work)
    }

    @Test func aTextFileIsSavedAndReadBackByItsPath() async throws {
        let (core, work) = try core()
        let file = work.appendingPathComponent("project/AGENTS.md").path
        let absent = try await core.handle(method: DaemonAPI.Method.filesReadText,
                                           params: try JSONValue.encoding(DaemonAPI.FilesTextRequest(path: file))).get()
        #expect(try absent.decode(DaemonAPI.FilesText.self).text == nil)
        _ = try await core.handle(method: DaemonAPI.Method.filesSaveText, params: try JSONValue.encoding(
            DaemonAPI.FilesSaveTextRequest(path: file, text: "# Rules\n"))).get()
        // A second write that only fills a gap leaves the first alone.
        _ = try await core.handle(method: DaemonAPI.Method.filesSaveText, params: try JSONValue.encoding(
            DaemonAPI.FilesSaveTextRequest(path: file, text: "other", onlyIfAbsent: true))).get()
        let read = try await core.handle(method: DaemonAPI.Method.filesReadText,
                                         params: try JSONValue.encoding(DaemonAPI.FilesTextRequest(path: file))).get()
        #expect(try read.decode(DaemonAPI.FilesText.self).text == "# Rules\n")
    }

    @Test func revealingSomethingThatIsNotThereSaysSo() async throws {
        let (core, work) = try core()
        let result = await core.handle(method: DaemonAPI.Method.macReveal, params: try JSONValue.encoding(
            DaemonAPI.MacPathRequest(path: work.appendingPathComponent("gone").path)))
        guard case .failure(let error) = result else { Issue.record("revealed a missing path"); return }
        #expect(error.code == DaemonAPI.Failure.fileGone)
    }

    /// A person's: the window, and since #111 a phone or a browser too. Never an agent.
    @Test func noAgentMayAskThem() {
        for method in [DaemonAPI.Method.macReveal, DaemonAPI.Method.macOpen, DaemonAPI.Method.macTerminal,
                       DaemonAPI.Method.filesReadText, DaemonAPI.Method.filesSaveText] {
            #expect(ConnectionRole.device.allows(method), "\(method)")
            #expect(ConnectionRole.control.allows(method), "\(method)")
            #expect(!ConnectionRole.agent.allows(method), "\(method)")
        }
    }
}
