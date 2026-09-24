import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A window asking the daemon to write what the person typed on the page.
///
/// The daemon writes rather than the window, so that it knows the person did: that is
/// what lets it tell the agent on the next turn. Everything checked here happens before
/// the file is touched — the agent is still here, the path is inside its folders — and
/// the note that goes out is exactly the contract's wording.
@Suite("Writing an artifact for the person", .timeLimit(.minutes(1)))
struct ArtifactWriteTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsArtifactWriteTests-\(UUID().uuidString)", isDirectory: true)
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
    private func mintedToken(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let minted = await token(launcher)
            return minted.isEmpty ? nil : minted
        } ?? ""
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
    }
}
