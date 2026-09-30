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

    /// OpenCode's own three answers, as 1.18.33 sends them (049 research R3).
    private func openCodePermission(command: String) -> JSONValue {
        .object([
            "toolCall": .object([
                "toolCallId": .string("call-1"), "title": .string(command), "kind": .string("execute"),
                "status": .string("pending"), "rawInput": .object(["command": .string(command)]),
            ]),
            "options": .array([
                .object(["optionId": .string("once"), "kind": .string("allow_once"), "name": .string("Allow once")]),
                .object(["optionId": .string("always"), "kind": .string("allow_always"), "name": .string("Always allow")]),
                .object(["optionId": .string("reject"), "kind": .string("reject_once"), "name": .string("Reject")]),
            ]),
        ])
    }

    @Test func openCodeAlwaysApproveAnswersOnceWithoutACard() async throws {
        let (_, work, locations) = try sandbox()
        #expect(ClientPermissionSettings.supports("opencode"))
        let (core, launcher) = try await core(locations: locations, permission: openCodePermission(command: "ls"),
                                              settings: .init(opencode: .alwaysApprove))
        let id = try await core.start(.init(runtimeID: "opencode", cwd: work, prompt: "run ls"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "once", "once, so switching back to Ask still asks")
        let page = try await core.transcript(.init(agentID: id))
        #expect(!page.entries.contains { if case .permissionAsked = $0.kind { return true } else { return false } })
    }

    @Test func openCodeAsksByDefault() async throws {
        let (_, work, locations) = try sandbox()
        let (core, _) = try await core(locations: locations, permission: openCodePermission(command: "ls"),
                                       settings: .init(cursor: .alwaysApprove, grok: .alwaysApprove))
        let id = try await core.start(.init(runtimeID: "opencode", cwd: work, prompt: "run ls"))
        await eventually("the card is held") { await core.agent(id)?.state == .waitingOnUser }
        let page = try await core.transcript(.init(agentID: id))
        #expect(page.entries.contains { if case .permissionAsked = $0.kind { return true } else { return false } },
                "Cursor's and Grok's choices are not OpenCode's")
    }

    /// A file saved before OpenCode was known (061's two keys) still loads, and asks for it.
    @Test func settingsSavedBeforeOpenCodeStillLoad() throws {
        let old = try JSONDecoder().decode(ClientPermissionSettings.self,
                                           from: Data(#"{"cursor":"alwaysApprove","grok":"default"}"#.utf8))
        #expect(old == .init(cursor: .alwaysApprove, grok: .default, opencode: .default))
        #expect(old.setting(.alwaysApprove, for: "opencode").opencode == .alwaysApprove)
        #expect(old.setting(.alwaysApprove, for: "claude") == old)
    }

    @Test func alwaysApproveAllowsEditWithoutAsking() async throws {
        let (_, work, locations) = try sandbox()
        let file = work.appendingPathComponent("notes.txt")
        let (core, launcher) = try await core(
            locations: locations,
            permission: editPermission(path: file.path),
            settings: .init(cursor: .alwaysApprove, grok: .default))
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

    @Test func alwaysApproveAllowsOutsidePathWithoutAsking() async throws {
        let (_, work, locations) = try sandbox()
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClientPermission-outside-\(UUID().uuidString).txt")
        let (core, launcher) = try await core(
            locations: locations,
            permission: editPermission(path: outside.path),
            settings: .init(cursor: .alwaysApprove, grok: .alwaysApprove))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "edit home"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "allow_once")
        let page = try await core.transcript(.init(agentID: id))
        #expect(!page.entries.contains { if case .permissionAsked = $0.kind { return true } else { return false } })
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
        let settings = ClientPermissionSettings(cursor: .alwaysApprove, grok: .default)

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

    @Test func settingsPersistAndCorruptFallsBackToDefault() throws {
        let (root, _, locations) = try sandbox()
        let store = ClientPermissionStore(locations: locations)
        try store.save(.init(cursor: .alwaysApprove, grok: .default))
        #expect(store.load().cursor == .alwaysApprove)
        #expect(store.load().grok == .default)

        let file = root.appendingPathComponent("client-permissions.json")
        try Data(#"{"cursor":"autoReview","grok":"autoReview"}"#.utf8).write(to: file)
        let migrated = store.load()
        #expect(migrated.cursor == .alwaysApprove)
        #expect(migrated.grok == .alwaysApprove)

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
        _ = try await core.setClientPermissions(.init(cursor: .alwaysApprove, grok: .default))
        let stillPending = await core.pendingPermissionRequests().first?.id
        #expect(stillPending == pendingID)
        if let request = await core.pendingPermissionRequests().first {
            try await core.answerPermission(.init(permissionID: request.id, optionID: "allow_once"))
        }
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
    }

    @Test func startAgentIsAllowedUnderAlwaysApprove() async throws {
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
        _ = try await core.setClientPermissions(.init(cursor: .alwaysApprove, grok: .alwaysApprove))
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "start"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "allow_once")
        #expect(await core.pendingPermissionRequests().isEmpty)
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
