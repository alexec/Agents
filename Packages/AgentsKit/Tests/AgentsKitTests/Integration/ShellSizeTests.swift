import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// One shell, looked at from the Mac and a phone at once (034).
///
/// The shell takes the size of whoever typed last, and a phone hears a shell only while
/// it has that shell open. A window on the Mac hears every shell, as it always has.
@Suite("A shell shared by the Mac and a phone", .timeLimit(.minutes(1)))
struct ShellSizeTests {
    actor Heard {
        private var sent: [(method: String, agentID: UUID?, to: Set<UUID>)] = []

        func record(_ method: String, _ params: JSONValue?, to: Set<UUID>) {
            var agentID: UUID?
            if let params, let output = DaemonAPI.ShellOutputNotification(params: params) {
                agentID = output.agentID
            } else if let state = try? params?.decode(DaemonAPI.ShellStateNotification.self) {
                agentID = state.agentID
            }
            sent.append((method, agentID, to))
        }

        func output(to connection: UUID, from agentID: UUID) -> Int {
            sent.filter {
                $0.method == DaemonAPI.Notification.shellOutput && $0.agentID == agentID && $0.to.contains(connection)
            }.count
        }

        func clear() { sent = [] }
    }

    private let window = UUID()
    private let phone = UUID()

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsShellSizeTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(locations: StoreLocations, heard: Heard) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.setBroadcaster { _, _ in }
        let window = window, phone = phone
        await core.setAddressedBroadcaster { method, params, wanted in
            var to: Set<UUID> = []
            if wanted(.init(id: window, surface: .mac)) { to.insert(window) }
            if wanted(.init(id: phone, surface: .device(phone))) { to.insert(phone) }
            Task { await heard.record(method, params, to: to) }
        }
        await core.connectShells()
        await core.setConnectionCount(1)
        return core
    }

    private func size(_ core: DaemonCore, _ agentID: UUID) async -> (Int, Int)? {
        guard let session = await core.shells.session(for: agentID) else { return nil }
        return (session.rows, session.cols)
    }

    @Test func theShellTakesTheSizeOfWhoeverTypedLast() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations: locations, heard: Heard())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = try await core.attachShell(.init(agentID: id, rows: 24, cols: 80))
        let atFirst = try #require(await size(core, id))
        #expect(atFirst == (24, 80))

        // The phone types, at the phone's size.
        try await core.writeToShell(.init(agentID: id, bytes: Data(" ".utf8), rows: 40, cols: 50))
        let phones = try #require(await size(core, id))
        #expect(phones == (40, 50))

        // Then the Mac, at its own.
        try await core.writeToShell(.init(agentID: id, bytes: Data(" ".utf8), rows: 30, cols: 120))
        let macs = try #require(await size(core, id))
        #expect(macs == (30, 120))
    }

    @Test func keystrokesWithoutASizeResizeNothing() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations: locations, heard: Heard())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = try await core.attachShell(.init(agentID: id, rows: 24, cols: 80))

        try await core.writeToShell(.init(agentID: id, bytes: Data(" ".utf8)))
        let after = try #require(await size(core, id))
        #expect(after == (24, 80))
    }

    @Test func aPhoneHearsAShellOnlyWhileItHasItOpen() async throws {
        let (locations, work) = try temporary()
        let heard = Heard()
        let core = try await core(locations: locations, heard: heard)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        // The Mac's window opens the shell and it prints: the window hears it, the
        // phone, which has not opened it, does not.
        _ = try await core.attachShell(.init(agentID: id, rows: 24, cols: 80), from: .mac, connection: window)
        try await core.writeToShell(.init(agentID: id, bytes: Data("echo before\n".utf8)))
        await eventually("the window heard the shell") { await heard.output(to: window, from: id) > 0 }
        #expect(await heard.output(to: phone, from: id) == 0)

        // The phone opens it: now both hear it.
        _ = try await core.attachShell(.init(agentID: id, rows: 40, cols: 50),
                                       from: .device(phone), connection: phone)
        await heard.clear()
        try await core.writeToShell(.init(agentID: id, bytes: Data("echo during\n".utf8)))
        await eventually("the phone heard the shell") { await heard.output(to: phone, from: id) > 0 }

        // The phone lets it go: the shell carries on, and the phone hears no more.
        await core.detachShell(DaemonAPI.ShellRequest(agentID: id), connection: phone)
        try await Task.sleep(for: .milliseconds(200))
        await heard.clear()
        try await core.writeToShell(.init(agentID: id, bytes: Data("echo after\n".utf8)))
        await eventually("the window still hears the shell") { await heard.output(to: window, from: id) > 0 }
        #expect(await heard.output(to: phone, from: id) == 0)
    }

    /// While a Mac window shows the shell it keeps the Mac's size, whoever types; once
    /// the window lets go, the phone's size is taken (Alex, #401).
    @Test func theMacsSizeWinsWhileAWindowShowsTheShell() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations: locations, heard: Heard())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = try await core.attachShell(.init(agentID: id, rows: 30, cols: 120), from: .mac, connection: window)
        _ = try await core.attachShell(.init(agentID: id, rows: 40, cols: 50),
                                       from: .device(phone), connection: phone)

        try await core.writeToShell(.init(agentID: id, bytes: Data(" ".utf8), rows: 40, cols: 50), from: .device(phone))
        await core.resizeShell(.init(agentID: id, rows: 40, cols: 50), from: .device(phone))
        let whileShown = try #require(await size(core, id))
        #expect(whileShown == (30, 120))

        await core.detachShell(DaemonAPI.ShellRequest(agentID: id), connection: window)
        await core.resizeShell(.init(agentID: id, rows: 40, cols: 50), from: .device(phone))
        let afterwards = try #require(await size(core, id))
        #expect(afterwards == (40, 50))
        await core.shells.shutDown()
    }

    @Test func attachingDoesNotResizeARunningShell() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations: locations, heard: Heard())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = try await core.attachShell(.init(agentID: id, rows: 30, cols: 120))
        _ = try await core.attachShell(.init(agentID: id, rows: 24, cols: 80))
        let after = try #require(await size(core, id))
        #expect(after == (30, 120))
        await core.shells.shutDown()
    }

    /// The daemon numbers new tabs, so two screens opening one at once get two (#401).
    @Test func theDaemonNumbersNewShells() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations: locations, heard: Heard())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = try await core.attachShell(.init(agentID: id))
        let first = try await core.openShell(.init(agentID: id))
        let second = try await core.openShell(.init(agentID: id))
        #expect(first.shell == 1)
        #expect(second.shell == 2)
        #expect(await core.listShells(id).shells == [0, 1, 2])
        await core.shells.shutDown()
    }

    @Test func aPhoneThatGoesAwayHearsNothingMore() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations: locations, heard: Heard())
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        _ = try await core.attachShell(.init(agentID: id, rows: 40, cols: 50),
                                       from: .device(phone), connection: phone)
        #expect(await core.shellWatchers[id] == [phone])
        await core.connectionEnded(phone)
        #expect(await core.shellWatchers[id] == nil)
    }
}
