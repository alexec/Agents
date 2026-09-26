import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Several shells for one agent, one per terminal tab (055).
///
/// Each is its own pty with its own output, told apart by number. Zero is the one every
/// agent had before there could be more, and a message without a number means it.
@Suite("Several shells for one agent", .timeLimit(.minutes(1)))
struct ShellTabsTests {
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var output: [Int: Data] = [:]

        func record(_ method: String, _ params: JSONValue?) {
            guard method == DaemonAPI.Notification.shellOutput, let params,
                  let heard = DaemonAPI.ShellOutputNotification(params: params) else { return }
            lock.lock(); defer { lock.unlock() }
            output[heard.shell, default: Data()].append(heard.bytes)
        }

        func text(of shell: Int) -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: output[shell] ?? Data(), as: UTF8.self)
        }
    }

    private func core(heard: Heard) async throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsShellTabsTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.setBroadcaster { method, params in heard.record(method, params) }
        await core.connectShells()
        await core.setConnectionCount(1)
        return (core, work)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test func twoShellsForOneAgentAreTwoShells() async throws {
        let heard = Heard()
        let (core, work) = try await core(heard: heard)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        #expect(await core.listShells(id).shells == [0])
        _ = try await core.attachShell(.init(agentID: id))
        _ = try await core.attachShell(.init(agentID: id, shell: 1))
        #expect(await core.listShells(id).shells == [0, 1])

        let first = await core.shells.session(for: id, shell: 0)
        let second = await core.shells.session(for: id, shell: 1)
        #expect(first != nil && second != nil && first !== second)

        // Typed into the second, heard from the second and not the first.
        let marker = "tab-\(UUID().uuidString.prefix(8))"
        try await core.writeToShell(.init(agentID: id, shell: 1, bytes: Data("echo \(marker)\n".utf8)))
        #expect(await eventually { heard.text(of: 1).contains(marker) })
        #expect(!heard.text(of: 0).contains(marker))

        // Closing ends that one and forgets it; the first carries on.
        await core.closeShell(.init(agentID: id, shell: 1))
        #expect(await core.listShells(id).shells == [0])
        #expect(await core.shells.session(for: id, shell: 1) == nil)
        #expect(second?.state.isLive == false)
        #expect(first?.state.isLive == true)

        await core.shells.shutDown()
    }

    @Test func aMessageWithoutANumberMeansTheFirstShell() throws {
        let agentID = UUID()
        let attach = try JSONDecoder().decode(DaemonAPI.ShellAttachRequest.self,
                                              from: Data(#"{"agentID":"\#(agentID)"}"#.utf8))
        #expect(attach.shell == 0)
        let input = try JSONDecoder().decode(DaemonAPI.ShellInputRequest.self,
                                             from: Data(#"{"agentID":"\#(agentID)","bytes":"aGk="}"#.utf8))
        #expect(input.shell == 0)
        let output = DaemonAPI.ShellOutputNotification(params: ["agentID": .string(agentID.uuidString),
                                                                "bytes": .string("aGk=")])
        #expect(output?.shell == 0)
        let numbered = DaemonAPI.ShellOutputNotification(params: ["agentID": .string(agentID.uuidString),
                                                                  "shell": .int(2),
                                                                  "bytes": .string("aGk=")])
        #expect(numbered?.shell == 2)
    }
}
