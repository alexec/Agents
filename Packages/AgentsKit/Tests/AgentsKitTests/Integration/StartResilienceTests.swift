import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Nothing a runtime sends inside its options, and no way a runtime refuses, may cost
/// the user an agent.
@Suite("Starting an agent whatever the runtime sends", .timeLimit(.minutes(1)))
struct StartResilienceTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsStartTests-\(UUID().uuidString)", isDirectory: true)
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

    @Test func anUnreadableOptionsListDoesNotStopTheAgentStarting() async throws {
        // The bug this feature exists to fix. A group where an option was expected used
        // to fail the decode of the whole `session/new` result, which failed the start.
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.rawConfigOptions = [
            ["id": "model", "name": "Model", "type": "select",
             "options": [["group": "fast", "name": "Fast",
                          "options": [["value": "haiku", "name": "Haiku"]]]]],
            ["nonsense": true],
            .string("not even an object"),
        ]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await eventually("the readable option came through") {
            await core.agent(id)?.advertisedOptions.isEmpty == false
        }

        let agent = await core.agent(id)
        #expect(agent != nil, "the agent started")
        #expect(agent?.advertisedOptions.map(\.id) == ["model"])
        #expect(agent?.advertisedOptions.first?.groups.first?.name == "Fast")
    }

    @Test func aRuntimeThatNeedsSigningInSaysSoRatherThanFailing() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.newSessionError = .authRequired("run `copilot login`")
        let core = try core(FakeLauncher(script: script), locations: locations)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        }
        do {
            _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.needsSignIn)
            #expect(error.message.contains("needs signing in"))
            #expect(error.data?["runtimeID"]?.stringValue == "copilot")
        }
        // And the runtime is marked, so the app can show it without asking again.
        #expect(await core.account(for: "copilot").state == .needsSignIn)
    }

    @Test func aRuntimeSpeakingAnotherVersionIsReportedPlainly() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(script: .init(protocolVersion: 7)), locations: locations)

        do {
            _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
            Issue.record("expected the version to be refused")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.wrongProtocolVersion)
            #expect(error.message.contains("version 7"))
        }
    }

    @Test func aBooleanOptionIsSetWithItsTypeNamed() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.rawConfigOptions = [["id": "fast", "name": "Fast", "category": "model_config",
                                    "type": "boolean", "currentValue": false]]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go",
                                            startOptions: .init(values: ["fast": .bool(true)])))
        await eventually("the option was set on the runtime") {
            await launcher.lastAgent?.setOptions.isEmpty == false
        }

        let agent = await core.agent(id)
        #expect(agent?.advertisedOptions.first?.isBoolean == true)
        let sent = await launcher.lastAgent?.setOptions
        #expect(sent?.first?.id == "fast")
        #expect(sent?.first?.value == .bool(true))
    }
}
