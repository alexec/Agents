import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent asking that a file be put in front of the user.
///
/// The other half of the MCP server the app serves every session. Everything worth
/// checking happens before any window hears about it: the token still speaks for an
/// agent, the path is one that agent was given, the file is there, and somebody is
/// there to see it. A window is not asked to be careful on the daemon's behalf.
@Suite("Showing the user a file", .timeLimit(.minutes(1)))
struct ShowFileTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsShowFileTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    /// A daemon with a window connected to it, listening to what it says.
    private func core(_ launcher: FakeLauncher, locations: StoreLocations,
                      watching: Broadcasts) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: launcher)
        await core.setBroadcaster { method, params in
            Task { await watching.record(method, params) }
        }
        await core.setConnectionCount(1)
        return core
    }

    /// A turn long enough to call a tool in the middle of, as a real one is.
    private func midTurn() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        return FakeLauncher(script: script)
    }

    private func token(_ launcher: FakeLauncher) async -> String {
        (await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue ?? [])
            .first?["args"]?.arrayValue?.last?.stringValue ?? ""
    }

    /// Wait until the runtime has actually been handed its token.
    ///
    /// It reaches the runtime in `session/new`, so there is a moment after `start`
    /// returns in which `token` is still the empty string, and a call made with that
    /// is refused for the wrong reason.
    private func mintedToken(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let minted = await token(launcher)
            return minted.isEmpty ? nil : minted
        } ?? ""
    }

    private func write(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data("one\ntwo\nthree\n".utf8).write(to: url)
        return url
    }

    @Test func aFileInTheAgentsFoldersReachesEveryWindow() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let heard = Broadcasts()
        let core = try await core(launcher, locations: locations, watching: heard)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        let file = try write("README.md", in: work)

        let note = try await core.showFile(.init(token: await mintedToken(launcher),
                                                 file: ShownFile(path: file.path, line: 2)))

        let sent = await heard.wait(for: DaemonAPI.Notification.agentShowFile)
        #expect(sent?["agentID"]?.stringValue == id.uuidString)
        #expect(sent?["file"]?["path"]?.stringValue == file.path)
        #expect(sent?["file"]?["line"]?.intValue == 2)
        // The agent is told where the person is now looking, in words it can repeat.
        #expect(note.contains("README.md"))
        #expect(note.contains("line 2"))
    }

    /// The rule the whole feature rests on: `show_file` is not a way to read a file
    /// the agent was never given, nor to put one in front of the user.
    @Test func aPathOutsideTheAgentsFoldersIsRefusedAndNothingIsSent() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let heard = Broadcasts()
        let core = try await core(launcher, locations: locations, watching: heard)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elsewhere-\(UUID().uuidString).txt")
        try Data("secret\n".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.showFile(.init(token: await mintedToken(launcher),
                                              file: ShownFile(path: outside.path)))
        }
        #expect(await heard.first(DaemonAPI.Notification.agentShowFile) == nil)
    }

    @Test func aFileThatIsNotThereIsRefused() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let heard = Broadcasts()
        let core = try await core(launcher, locations: locations, watching: heard)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.showFile(.init(
                token: await mintedToken(launcher),
                file: ShownFile(path: work.appendingPathComponent("imagined.swift").path)))
        }
        #expect(await heard.first(DaemonAPI.Notification.agentShowFile) == nil)
    }

    /// 022: a Markdown file is a page that fills as it is written, so showing it
    /// before the first write is the right moment, not a mistake. The folder has to
    /// be there; the file does not.
    @Test func aMarkdownFileNotYetWrittenIsShownEmpty() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let heard = Broadcasts()
        let core = try await core(launcher, locations: locations, watching: heard)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let path = work.appendingPathComponent("notes.md").path
        let reply = try await core.showFile(.init(token: await mintedToken(launcher),
                                                  file: ShownFile(path: path)))
        #expect(reply.contains("empty"))
        #expect(reply.contains("fill"))
        let sent = await heard.wait(for: DaemonAPI.Notification.agentShowFile)
        #expect(sent?["file"]?["path"]?.stringValue == path)

        // But not in a folder that is not there: that is a path the agent cannot
        // write to either, and the page would wait for ever.
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.showFile(.init(
                token: await mintedToken(launcher),
                file: ShownFile(path: work.appendingPathComponent("nowhere/notes.md").path)))
        }
    }

    @Test func aFolderIsNotAFile() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let heard = Broadcasts()
        let core = try await core(launcher, locations: locations, watching: heard)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.showFile(.init(token: await mintedToken(launcher),
                                              file: ShownFile(path: work.path)))
        }
    }

    @Test func aTokenTheDaemonDoesNotKnowIsRefused() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let heard = Broadcasts()
        let core = try await core(launcher, locations: locations, watching: heard)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        let file = try write("README.md", in: work)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.showFile(.init(token: "not-a-token",
                                              file: ShownFile(path: file.path)))
        }
    }

    /// Unlike a suggestion, which waits on the agent's record for a window to open,
    /// this one has nowhere to wait. The agent is told so rather than left believing
    /// somebody is reading.
    @Test func withNoWindowOpenTheAgentIsToldSo() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let heard = Broadcasts()
        let core = try await core(launcher, locations: locations, watching: heard)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        let file = try write("README.md", in: work)
        await core.setConnectionCount(0)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.showFile(.init(token: await mintedToken(launcher),
                                              file: ShownFile(path: file.path)))
        }
        #expect(await heard.first(DaemonAPI.Notification.agentShowFile) == nil)
    }

    /// Everything the daemon told the windows, in order.
    private actor Broadcasts {
        private var sent: [(String, JSONValue?)] = []

        func record(_ method: String, _ params: JSONValue?) {
            sent.append((method, params))
        }

        func first(_ method: String) -> JSONValue? {
            sent.first { $0.0 == method }?.1
        }

        /// Broadcasting is a hand-off to another task, so what the daemon has said and
        /// what this has heard are a moment apart. Waited for rather than slept past.
        func wait(for method: String) async -> JSONValue? {
            let deadline = ContinuousClock.now.advanced(by: max(.seconds(2), Eventually.timeout))
            while ContinuousClock.now < deadline {
                if let found = first(method) { return found }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
    }
}
