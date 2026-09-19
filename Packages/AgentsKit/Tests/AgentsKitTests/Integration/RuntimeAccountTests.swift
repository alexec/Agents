import Foundation
import Testing
@testable import AgentsKit

/// "Installed but not usable" is a state the app already detected and could not fix.
@Suite("Signing in and out", .timeLimit(.minutes(1)))
struct RuntimeAccountTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsAccountTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    @Test func aHandshakeRecordsWhatTheRuntimeSaidAboutItself() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.agentCapabilities = ["auth": ["logout": [:]],
                                    "promptCapabilities": ["image": true, "embeddedContext": true]]
        let core = try core(FakeLauncher(script: script), locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        try await Task.sleep(for: .milliseconds(200))

        let account = await core.account(for: "claude")
        #expect(account.state == .ready)
        #expect(account.canLogOut)
        #expect(account.promptCapabilities.allows(.image))
        #expect(!account.promptCapabilities.allows(.audio))
    }

    @Test func aRefusalMovesTheRuntimeToNeedingSignIn() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.newSessionError = .authRequired("not signed in")
        let core = try core(FakeLauncher(script: script), locations: locations)

        _ = try? await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        #expect(await core.account(for: "copilot").state == .needsSignIn)
    }

    @Test func signingInFromTheAppMakesTheRuntimeUsable() async throws {
        let (locations, _) = try temporary()
        var refuses = FakeACPAgent.Script()
        refuses.newSessionError = .authRequired("not signed in")
        // The scripted ones are used first, so the first launch refuses and every
        // launch after it is an ordinary runtime.
        let launcher = FakeLauncher(script: .init(), then: [refuses])
        let core = try core(launcher, locations: locations)

        let (locations2, work) = try temporary()
        _ = locations2
        do {
            _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.needsSignIn, "got \(error.code): \(error.message)")
        }
        #expect(await core.account(for: "copilot").state == .needsSignIn)

        let account = try await core.authenticate(runtimeID: "copilot", methodID: "copilot-login")
        #expect(account.state == .ready)
    }

    @Test func aMethodThatNeedsATerminalHandsBackTheCommandRatherThanRunningIt() async throws {
        let (locations, _) = try temporary()
        var script = FakeACPAgent.Script()
        // The shape Copilot actually sends, `_meta.terminal-auth` and all.
        script.agentCapabilities = [:]
        let launcher = FakeLauncherWithAuth(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: launcher)

        do {
            _ = try await core.authenticate(runtimeID: "copilot", methodID: "copilot-login")
            Issue.record("expected the command to come back instead")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.needsSignIn)
            #expect(error.data?["command"]?.stringValue == "/opt/homebrew/bin/copilot login")
            #expect(error.message.contains("in a terminal"))
        }
    }

    @Test func signingOutSaysWhichAgentsItStops() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.agentCapabilities = ["auth": ["logout": [:]]]
        // Keep the first agent running: a question it is waiting on.
        script.permission = ["toolCall": ["title": "Something"],
                             "options": [["optionId": "allow_once", "name": "Allow", "kind": "allow_once"]]]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.agent(id)?.state == .waitingOnUser)

        let stopped = try await core.logOut(runtimeID: "claude")
        #expect(stopped == [id], "those agents are mid-conversation")
        #expect(await core.account(for: "claude").state == .needsSignIn)
    }
}

/// A launcher whose agent advertises Copilot's terminal sign-in method.
final class FakeLauncherWithAuth: SessionLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [FakeACPAgent] = []
    private let script: FakeACPAgent.Script

    init(script: FakeACPAgent.Script) {
        self.script = script
    }

    func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
        var script = self.script
        script.authMethods = [["id": "copilot-login", "name": "Log in with Copilot CLI",
                               "_meta": ["terminal-auth": ["command": "/opt/homebrew/bin/copilot",
                                                           "args": ["login"]]]]]
        let (mine, theirs) = PairedTransport.pair()
        let session = ACPSession(transport: mine)
        let agent = FakeACPAgent(script: script, transport: theirs)
        lock.lock()
        agents.append(agent)
        lock.unlock()
        return session
    }
}
