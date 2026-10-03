import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent, or a workflow, choosing the runtime a new agent starts on (#117).
///
/// Any runtime that can take an agent here may be named; one that cannot — not
/// installed, not signed in, out of the pool — is refused before anything starts, in
/// words, with the ones that can; a name this version does not know is refused as it
/// always was. The words are checked as well as the effect, because an agent reads them.
@Suite("Choosing a runtime for a new agent", .timeLimit(.minutes(1)))
struct RuntimeChoiceTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsRuntimeChoice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work.resolvingSymlinksInPath()))
    }

    /// Everything found but Cursor, which is not installed.
    private func makeCore(_ locations: StoreLocations,
                          _ launcher: FakeLauncher = FakeLauncher()) async throws -> DaemonCore {
        var discovery = RuntimeDiscovery.findsEverything
        discovery.fileExists = { !$0.hasSuffix("/cursor-agent") }
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    /// An agent the person started, and a token that speaks for it, bound again before
    /// each call: a fake agent's turn ends when it likes, and its token with it.
    private func caller(_ core: DaemonCore, in folder: URL) async throws -> (UUID, String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: "Lead"))
        return (id, UUID().uuidString)
    }

    private func startHelper(_ core: DaemonCore, _ lead: (UUID, String),
                             runtime: String?) async throws -> (note: String, agentID: UUID) {
        await core.bindAppToken(lead.1, to: lead.0)
        return try await core.startHelper(.init(token: lead.1, prompt: "Count the files", runtime: runtime))
    }

    private func refusal(_ body: () async throws -> Void) async -> JSONRPCError? {
        do { try await body(); return nil } catch let error as JSONRPCError { return error } catch { return nil }
    }

    // MARK: start_agent

    @Test func anAvailableRuntimeStartsTheHelperOnIt() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations)
        let lead = try await caller(core, in: work)

        let started = try await startHelper(core, lead, runtime: "codex")

        #expect(await core.agent(started.agentID)?.runtimeID == "codex")
    }

    @Test func aRuntimeOutOfThePoolIsRefusedWithTheAvailableOnes() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations)
        let lead = try await caller(core, in: work)
        await core.runtimeFailed(runtimeID: "grok")
        let before = await core.allAgents().count

        let error = await refusal { _ = try await startHelper(core, lead, runtime: "grok") }

        let message = try #require(error?.message)
        #expect(message.hasPrefix("Nothing was started: Grok isn't available on this Mac (out of the pool: "))
        #expect(message.hasSuffix("Available: antigravity, claude, codex, copilot, gemini, opencode."))
        #expect(await core.allAgents().count == before)
    }

    @Test func aRuntimeNotInstalledIsRefusedSayingSo() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations)
        let lead = try await caller(core, in: work)

        let error = await refusal { _ = try await startHelper(core, lead, runtime: "cursor") }

        #expect(error?.message
                == "Nothing was started: Cursor isn't available on this Mac (not installed). "
                + "Available: antigravity, claude, codex, copilot, gemini, grok, opencode.")
    }

    @Test func theDefaultRuntimeIsCheckedWhenNoneIsNamed() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations)
        let lead = try await caller(core, in: work)
        await core.runtimeFailed(runtimeID: "claude")

        let error = await refusal { _ = try await startHelper(core, lead, runtime: nil) }

        #expect(error?.message.hasPrefix("Nothing was started: Claude isn't available on this Mac") == true)
    }

    @Test func anUnknownRuntimeIsRefusedAsBefore() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations)
        let lead = try await caller(core, in: work)

        let error = await refusal { _ = try await startHelper(core, lead, runtime: "nonesuch") }

        #expect(error?.message == "Nothing was started: There is no runtime called \"nonesuch\" — this version knows "
                + RuntimeCatalog.builtIn.map(\.id).joined(separator: ", ") + ".")
    }

    @Test func aModelTheRuntimeDoesNotOfferIsRefusedNamingTheOnesItDoes() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.configOptions = [
            ConfigOption(id: "model", name: "Model", category: "model", type: "select",
                         currentValue: .string("opus"),
                         options: ["opus", "haiku"].map { ConfigChoice(value: .string($0), name: $0) }),
        ]
        let core = try await makeCore(locations, FakeLauncher(script: script))
        let lead = try await caller(core, in: work)
        let before = await core.allAgents().count

        await core.bindAppToken(lead.1, to: lead.0)
        let error = await refusal {
            _ = try await core.startHelper(.init(token: lead.1, prompt: "Go", runtime: "claude", model: "gpt-9"))
        }

        #expect(error?.message.hasPrefix("Nothing was started: \"gpt-9\" is not ") == true)
        #expect(error?.message.contains("opus, haiku") == true)
        #expect(await core.allAgents().count == before)
    }

    @Test func listingSaysWhichRuntimesCanBeNamedAndWhyNotTheRest() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations)
        let lead = try await caller(core, in: work)
        await core.runtimeFailed(runtimeID: "grok")

        await core.bindAppToken(lead.1, to: lead.0)
        let list = try await core.listHelpers(.init(token: lead.1))

        #expect(list.contains("Runtimes you can start agents on (claude if you name none): "))
        #expect(list.contains("codex"))
        #expect(list.contains("Not available on this Mac: cursor (not installed), grok (out of the pool: "),
                "alphabetical by name (#154)")
    }

    // MARK: A workflow's runtime:

    @Test func aWorkflowNamingAnUnavailableRuntimeIsRefusedOnTheRecord() async throws {
        let (locations, work) = try temporary()
        let folder = WorkflowFile.folder(in: work)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            ---
            on:
              - schedule:
                  at: [":00"]
            agent: new
            runtime: cursor
            ---

            Say hello and stop.
            """.utf8).write(to: WorkflowFile.url(for: "say-hello", in: work))
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        await core.rescanWorkflows(in: work)

        let summary = try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "say-hello"))

        #expect(await core.allAgents().isEmpty)
        #expect(launcher.launchCount == 0)
        guard case .refused(.settingRefused(let setting, let detail), _, _) = summary.lastOutcome else {
            Issue.record("expected a settings refusal, got \(String(describing: summary.lastOutcome))")
            return
        }
        #expect(setting == WorkflowSettings.Setting.runtime)
        #expect(detail == "Cursor isn't available on this Mac (not installed). "
                + "Available: antigravity, claude, codex, copilot, gemini, grok, opencode")
    }
}
