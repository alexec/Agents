import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A tool we could not take away.
///
/// Most of this app's scoping needs no test at the daemon level: a tool that was
/// removed is not there, and the model never sees it. `ToolScopingTests` holds the
/// other half — that a removal actually leaves the building, on every door into a
/// conversation. This file is about the remainder: where a runtime kept a rival anyway,
/// the daemon answers for it rather than putting a question nobody can act on in front
/// of the person.
///
/// It is the second line of defence and never the first. A runtime that auto-approves
/// its own tools never asks at all, which is why the briefing carries the residue too.
@Suite("A tool we could not take away", .timeLimit(.minutes(1)))
struct ResidualToolTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsResidualTests-\(UUID().uuidString)", isDirectory: true)
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

    private func notes(_ core: DaemonCore, _ id: UUID) async -> [String] {
        let page = try? await core.transcript(.init(agentID: id))
        return (page?.entries ?? []).compactMap {
            if case .runtimeNote(let note) = $0.kind { return note } else { return nil }
        }
    }

    // MARK: What the daemon answers for itself

    /// Grok keeps `workflow` whatever we ask, so the second line of defence is this:
    /// where the runtime is polite enough to ask, the app says no in a sentence the
    /// agent can act on, and the person is never shown a question about a tool that was
    /// never going to be allowed.
    @Test func aResidualToolIsRefusedWithTheSentenceFromItsCategory() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "call-1", "title": "workflow", "name": "workflow"],
            "options": .array([
                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
            ]),
        ]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the question was answered for us") {
            await launcher.lastAgent?.permissionOutcome != nil
        }

        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "reject")
        // Never held, never put in front of anybody, and the agent was not parked
        // waiting for an answer that was never coming.
        #expect(await core.pendingPermissionRequests().isEmpty)
        #expect(await core.agent(id)?.state != .waitingOnUser)
        // And the conversation says what happened, naming the tool to use instead.
        let said = await notes(core, id)
        #expect(said.contains { $0.contains("`workflow`") && $0.contains(AppTool.manageWorkflows) })
    }

    /// The mirror of the test above, and the one that stops this becoming a blunt
    /// instrument: an ordinary tool on the same runtime is still the person's to allow.
    @Test func everyOtherToolIsStillTheirs() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "call-1", "title": "Delete everything", "name": "rm_rf"],
            "options": .array([
                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
            ]),
        ]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "go"))
        await eventually("the question reached the daemon") {
            await core.pendingPermissionRequests().count == 1
        }

        #expect(await core.pendingPermissionRequests().count == 1)
    }

    /// And on a runtime whose rivals were actually removed there is nothing to refuse,
    /// so a tool of the same name is an ordinary question. This is what keeps the
    /// refusal reading off the policy rather than off a list of names.
    @Test func theSameNameOnAScopedRuntimeIsJustAQuestion() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "call-1", "title": "workflow", "name": "workflow"],
            "options": .array([
                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
            ]),
        ]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("the question reached the daemon") {
            await core.pendingPermissionRequests().count == 1
        }

        #expect(await core.pendingPermissionRequests().count == 1)
    }

    /// Found through a runtime's own prefix, because a runtime is free to rename what
    /// it offers on the way past and none of them changes what follows the prefix.
    @Test func evenWhenTheRuntimePrefixesTheName() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "call-1", "title": "monitor", "name": "mcp__grok__monitor"],
            "options": .array([
                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
            ]),
        ]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "watch that for me"))
        await eventually("the question was answered for us") {
            await launcher.lastAgent?.permissionOutcome != nil
        }

        #expect(await core.pendingPermissionRequests().isEmpty)
    }
}
