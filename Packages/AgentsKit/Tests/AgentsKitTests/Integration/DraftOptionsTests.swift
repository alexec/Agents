import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a start form is drawn from.
///
/// Asking a runtime what it offers means starting one, which is seconds. The answer is
/// remembered, so the second form for the same runtime and folder is drawn at once and
/// corrected if the runtime has since changed its mind.
@Suite("Draft options", .timeLimit(.minutes(1)))
struct DraftOptionsTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsDraftOptionsTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations,
                      watching: Broadcasts? = nil,
                      discovery: RuntimeDiscovery = .findsEverything) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: discovery,
                              launcher: launcher)
        if let watching {
            await core.setBroadcaster { method, params in
                Task { await watching.record(method, params) }
            }
        }
        return core
    }

    private func offering(_ models: [String]) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.configOptions = [ConfigOption(id: "model", name: "Model", category: "model",
                                             type: "select", currentValue: .string(models[0]),
                                             options: models.map { ConfigChoice(value: .string($0), name: $0) })]
        return FakeLauncher(script: script)
    }

    private func models(in options: [ConfigOption]) -> [String] {
        (options.first { $0.id == "model" }?.options ?? []).compactMap(\.value.stringValue)
    }

    @Test func theSecondFormIsDrawnFromWhatTheRuntimeSaidTheFirstTime() async throws {
        let (locations, work) = try temporary()
        _ = try await core(offering(["a", "b"]), locations: locations)
            .options(.init(runtimeID: "copilot", cwd: work))

        // A second daemon, over the same store, whose runtime now offers something else.
        let watching = Broadcasts()
        let later = try await core(offering(["c", "d"]), locations: locations, watching: watching)
        let form = try await later.options(.init(runtimeID: "copilot", cwd: work))

        #expect(models(in: form.options) == ["a", "b"],
                "answered from memory rather than waiting for the runtime to say it again")

        let correction = await watching.wait(for: DaemonAPI.Notification.draftOptions)
        let sent = try #require(try correction?.decode(DaemonAPI.DraftOptionsNotification.self))
        #expect(sent.draftID == form.draftID)
        #expect(models(in: sent.options) == ["c", "d"], "and put right when it says otherwise")
    }

    @Test func aFormThatWasAlreadyRightIsLeftAlone() async throws {
        let (locations, work) = try temporary()
        _ = try await core(offering(["a", "b"]), locations: locations)
            .options(.init(runtimeID: "copilot", cwd: work))

        let watching = Broadcasts()
        let later = try await core(offering(["a", "b"]), locations: locations, watching: watching)
        _ = try await later.options(.init(runtimeID: "copilot", cwd: work))
        // An absence, so there is no condition to wait for and time passing is the
        // assertion. Generous on purpose: the notification this is proving does not
        // arrive would arrive well inside a second if it were coming at all.
        try await Task.sleep(for: .milliseconds(700))

        #expect(await watching.first(DaemonAPI.Notification.draftOptions) == nil,
                "nothing moved, so the window is not told to redraw")
    }

    @Test func adifferentFolderIsADifferentQuestion() async throws {
        let (locations, work) = try temporary()
        let elsewhere = work.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        _ = try await core(offering(["a", "b"]), locations: locations)
            .options(.init(runtimeID: "copilot", cwd: work))

        let later = try await core(offering(["c", "d"]), locations: locations)
        let form = try await later.options(.init(runtimeID: "copilot", cwd: elsewhere))

        #expect(models(in: form.options) == ["c", "d"], "nothing is remembered about this folder")
    }

    @Test func aRememberedFormWhoseRuntimeWillNotStartSaysSo() async throws {
        let (locations, work) = try temporary()
        _ = try await core(offering(["a", "b"]), locations: locations)
            .options(.init(runtimeID: "copilot", cwd: work))

        let watching = Broadcasts()
        let later = try await core(offering(["a", "b"]), locations: locations, watching: watching,
                                   discovery: RuntimeDiscovery(searchPaths: ["/nowhere"],
                                                               fileExists: { _ in false }))
        // The form still appears: it is what this runtime offered last time, and the
        // answer went back before anybody knew the runtime had gone.
        let form = try await later.options(.init(runtimeID: "copilot", cwd: work))
        #expect(models(in: form.options) == ["a", "b"])

        let told = await watching.wait(for: DaemonAPI.Notification.draftOptions)
        let sent = try #require(try told?.decode(DaemonAPI.DraftOptionsNotification.self))
        #expect(sent.draftID == form.draftID)
        #expect(sent.failure?.contains("not installed") == true,
                "and the news arrives before the user has typed a prompt into it")
    }

    @Test func theDraftBehindARememberedFormIsTheSessionTheAgentStartsIn() async throws {
        let (locations, work) = try temporary()
        _ = try await core(offering(["a", "b"]), locations: locations)
            .options(.init(runtimeID: "copilot", cwd: work))

        let launcher = offering(["a", "b"])
        let later = try await core(launcher, locations: locations)
        let form = try await later.options(.init(runtimeID: "copilot", cwd: work))
        let id = try await later.start(.init(runtimeID: "copilot", cwd: work, prompt: "go",
                                             startOptions: StartOptions(values: ["model": "b"]),
                                             draftID: form.draftID))
        // Read here, before the turn has ended: the claim is about the start, and a
        // turn that ends without saying how it went is asked, which starts a runtime of
        // its own a moment later.
        #expect(launcher.launchCount == 1, "the runtime started behind the form is the one used")
        await eventually("the turn ran to its end") { await later.agent(id)?.state == .finished }
        #expect(await later.agent(id)?.state == .finished)
        // The first runtime's, not the last one's: the turn's ending is asked about,
        // and that question starts a runtime of its own with no options set on it.
        let applied = await launcher.allAgents.first?.setOptions
        #expect(applied?.first?.value.stringValue == "b")
    }

    actor Broadcasts {
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
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if let found = first(method) { return found }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
    }
}
