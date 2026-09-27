import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Client permission mode", .timeLimit(.minutes(2)))
struct ClientPermissionTests {
    private func sandbox() throws -> (root: URL, work: URL, locations: StoreLocations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClientPermission-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (root, work, StoreLocations(root: root))
    }

    private func editPermission(path: String) -> JSONValue {
        .object([
            "toolCall": .object([
                "toolCallId": .string("c1"),
                "title": .string("Edit \(path)"),
                "kind": .string("edit"),
                "status": .string("pending"),
                "rawInput": .object(["path": .string(path)]),
            ]),
            "options": .array([
                .object(["optionId": .string("allow_once"), "name": .string("Allow Once"),
                         "kind": .string("allow_once")]),
                .object(["optionId": .string("allow_always"), "name": .string("Allow Always"),
                         "kind": .string("allow_always")]),
                .object(["optionId": .string("reject_once"), "name": .string("Deny"),
                         "kind": .string("reject_once")]),
            ]),
        ])
    }

    private func core(locations: StoreLocations, permission: JSONValue,
                      settings: ClientPermissionSettings = .init()) async throws -> (DaemonCore, FakeLauncher) {
        var script = FakeACPAgent.Script()
        script.permission = permission
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        _ = try await core.setClientPermissions(settings)
        return (core, launcher)
    }

    @Test func autoReviewAllowsInReachEditWithoutAsking() async throws {
        let (_, work, locations) = try sandbox()
        let file = work.appendingPathComponent("notes.txt")
        let (core, launcher) = try await core(
            locations: locations,
            permission: editPermission(path: file.path),
            settings: .init(cursor: .autoReview, grok: .default))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "edit"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "selected")
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "allow_once")
        let page = try await core.transcript(.init(agentID: id))
        #expect(!page.entries.contains { if case .permissionAsked = $0.kind { return true } else { return false } })
        let pending = await core.pendingPermissionRequests()
        #expect(pending.isEmpty)
    }

    @Test func defaultStillAsksForTheSameEdit() async throws {
        let (_, work, locations) = try sandbox()
        let file = work.appendingPathComponent("notes.txt")
        let (core, launcher) = try await core(
            locations: locations,
            permission: editPermission(path: file.path),
            settings: .init(cursor: .default, grok: .default))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "edit"))
        await eventually("permission is pending") {
            !(await core.pendingPermissionRequests()).isEmpty
        }
        let state = await core.agent(id)?.state
        let pending = await core.pendingPermissionRequests()
        #expect(state == .waitingOnUser || !pending.isEmpty)
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome == nil)
        let page = try await core.transcript(.init(agentID: id))
        #expect(page.entries.contains { if case .permissionAsked = $0.kind { return true } else { return false } })
        if let request = pending.first {
            try await core.answerPermission(.init(permissionID: request.id, optionID: "allow_once"))
        }
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
    }

    @Test func runtimesAreIndependent() async throws {
        let (_, work, locations) = try sandbox()
        let file = work.appendingPathComponent("notes.txt")
        let settings = ClientPermissionSettings(cursor: .autoReview, grok: .default)

        let (cursorCore, cursorLauncher) = try await core(
            locations: locations,
            permission: editPermission(path: file.path), settings: settings)
        let cursorID = try await cursorCore.start(.init(runtimeID: "cursor", cwd: work, prompt: "edit"))
        await eventually("cursor finished") { await cursorCore.agent(cursorID)?.endedReason != nil }
        let cursorOutcome = await cursorLauncher.lastAgent?.permissionOutcome
        #expect(cursorOutcome?["outcome"]?["optionId"]?.stringValue == "allow_once")

        let (grokCore, grokLauncher) = try await core(
            locations: locations,
            permission: editPermission(path: file.path), settings: settings)
        let grokID = try await grokCore.start(.init(runtimeID: "grok", cwd: work, prompt: "edit"))
        await eventually("grok is waiting") { !(await grokCore.pendingPermissionRequests()).isEmpty }
        let grokOutcome = await grokLauncher.lastAgent?.permissionOutcome
        #expect(grokOutcome == nil)
        if let request = await grokCore.pendingPermissionRequests().first {
            try await grokCore.answerPermission(.init(permissionID: request.id, optionID: "reject_once"))
        }
        await eventually("grok finished") { await grokCore.agent(grokID)?.endedReason != nil }
    }

    @Test func outsidePathStaysPendingUnderAutoReview() async throws {
        let (_, work, locations) = try sandbox()
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClientPermission-outside-\(UUID().uuidString).txt")
        let (core, _) = try await core(
            locations: locations,
            permission: editPermission(path: outside.path),
            settings: .init(cursor: .autoReview, grok: .autoReview))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "edit home"))
        await eventually("outside edit waits") { !(await core.pendingPermissionRequests()).isEmpty }
        let page = try await core.transcript(.init(agentID: id))
        #expect(page.entries.contains { if case .permissionAsked = $0.kind { return true } else { return false } })
        if let request = await core.pendingPermissionRequests().first {
            try await core.answerPermission(.init(permissionID: request.id, optionID: "reject_once"))
        }
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
    }

    @Test func settingsPersistAndCorruptFallsBackToDefault() throws {
        let (root, _, locations) = try sandbox()
        let store = ClientPermissionStore(locations: locations)
        try store.save(.init(cursor: .autoReview, grok: .default))
        #expect(store.load().cursor == .autoReview)
        #expect(store.load().grok == .default)

        let file = root.appendingPathComponent("client-permissions.json")
        try Data("{not json".utf8).write(to: file)
        let recovered = store.load()
        #expect(recovered.cursor == .default)
        #expect(recovered.grok == .default)
    }

    @Test func changingSettingDoesNotTouchAnExistingCard() async throws {
        let (_, work, locations) = try sandbox()
        let file = work.appendingPathComponent("notes.txt")
        let (core, _) = try await core(
            locations: locations,
            permission: editPermission(path: file.path),
            settings: .init(cursor: .default, grok: .default))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "edit"))
        await eventually("card is pending") { !(await core.pendingPermissionRequests()).isEmpty }
        let pendingID = await core.pendingPermissionRequests().first?.id
        _ = try await core.setClientPermissions(.init(cursor: .autoReview, grok: .default))
        let stillPending = await core.pendingPermissionRequests().first?.id
        #expect(stillPending == pendingID)
        if let request = await core.pendingPermissionRequests().first {
            try await core.answerPermission(.init(permissionID: request.id, optionID: "allow_once"))
        }
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
    }

    @Test func startAgentStillAsksUnderAutoReview() async throws {
        let (_, work, locations) = try sandbox()
        var script = FakeACPAgent.Script()
        script.permission = .object([
            "toolCall": .object([
                "toolCallId": .string("c1"),
                "title": .string("agents_start_agent"),
                "name": .string("agents_start_agent"),
                "kind": .string("other"),
                "status": .string("pending"),
            ]),
            "options": .array([
                .object(["optionId": .string("allow_once"), "name": .string("Allow Once"),
                         "kind": .string("allow_once")]),
                .object(["optionId": .string("reject_once"), "name": .string("Deny"),
                         "kind": .string("reject_once")]),
            ]),
        ])
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        _ = try await core.setClientPermissions(.init(cursor: .autoReview, grok: .autoReview))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "start"))
        await eventually("start_agent waits") { !(await core.pendingPermissionRequests()).isEmpty }
        if let request = await core.pendingPermissionRequests().first {
            try await core.answerPermission(.init(permissionID: request.id, optionID: "reject_once"))
        }
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
    }

    @Test func controlOnlyRoles() {
        #expect(ConnectionRole.control.allows(DaemonAPI.Method.clientPermissionsState))
        #expect(ConnectionRole.control.allows(DaemonAPI.Method.clientPermissionsSet))
        #expect(!ConnectionRole.device.allows(DaemonAPI.Method.clientPermissionsState))
        #expect(!ConnectionRole.device.allows(DaemonAPI.Method.clientPermissionsSet))
        #expect(!ConnectionRole.agent.allows(DaemonAPI.Method.clientPermissionsSet))
    }

    @Test func grokLaunchForcesDefaultPermissionMode() {
        #expect(RuntimeCatalog.grok.arguments == ["--permission-mode", "default", "agent", "stdio"])
    }
}
