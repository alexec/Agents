import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// Workspace providers on the control plane (#691): adding one, linking a host to its
// workspace, and Start and Stop, against a stand-in provider. A host comes online by the
// router being told so, as its uplink would.

/// A provider whose workspaces are what the test says, and which records every call.
actor StandInProvider: WorkspaceProvider {
    var workspaces: [DaemonAPI.WorkspaceInfo]
    var refuse: String?
    var failStart: String?
    var starts = 0
    var stops = 0
    /// How long a start takes before it answers.
    var startTakes: Duration = .zero

    init(_ workspaces: [DaemonAPI.WorkspaceInfo]) { self.workspaces = workspaces }

    func set(refuse: String? = nil, failStart: String? = nil, startTakes: Duration = .zero) {
        self.refuse = refuse
        self.failStart = failStart
        self.startTakes = startTakes
    }

    func check() async throws -> ProviderConnection.Checked {
        if let refuse { throw ProviderFailure(refuse) }
        return .init(workspaces: workspaces)
    }

    func list() async throws -> [DaemonAPI.WorkspaceInfo] { workspaces }

    func start(_ id: String) async throws -> DaemonAPI.WorkspaceInfo? {
        starts += 1
        try? await Task.sleep(for: startTakes)
        if let failStart { throw ProviderFailure(failStart) }
        setState(id, "running")
        return workspaces.first { $0.id == id }
    }

    func stop(_ id: String) async throws -> DaemonAPI.WorkspaceInfo? {
        stops += 1
        setState(id, "stopped")
        return workspaces.first { $0.id == id }
    }

    /// What making a workspace does (US5): whether it runs the first boot, and what it was given.
    var firstBootRuns = true
    var firstBoots: [String] = []
    var deleted: [String] = []

    func set(firstBootRuns: Bool) { self.firstBootRuns = firstBootRuns }

    func options() async throws -> JSONValue {
        ["type": "object", "properties": ["size": ["type": "string", "title": "Size", "enum": ["small", "big"],
                                                    "x-costs": ["small": "$0.01/hour", "big": "$0.05/hour"]]]]
    }

    func create(name: String, options: JSONValue, firstBoot: String?) async throws -> (DaemonAPI.WorkspaceInfo?, Bool) {
        if let firstBoot { firstBoots.append(firstBoot) }
        let made = DaemonAPI.WorkspaceInfo(id: "ws-\(name)", name: name, state: "starting", ssh: "root@10.0.0.9")
        workspaces.append(made)
        return (made, firstBootRuns)
    }

    func delete(_ id: String) async throws {
        deleted.append(id)
        workspaces.removeAll { $0.id == id }
    }

    func end() async {}

    private func setState(_ id: String, _ state: String) {
        guard let n = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[n].state = state
    }
}

/// Records how many times agentsd was started over ssh, and where.
final class SSHStarts: @unchecked Sendable {
    private let lock = NSLock()
    private var _destinations: [String] = []
    var destinations: [String] { lock.withLock { _destinations } }
    func add(_ destination: String) { lock.withLock { _destinations.append(destination) } }
}

struct ProviderHarness {
    let store = MemoryStore()
    let records: ControlRecords
    let methods: ControlMethods
    let router: ControlRouter
    let providers: WorkspaceProviders
    let provider: StandInProvider
    let home: URL
    let sshStarts = SSHStarts()
    let devbox = HostID(rawValue: "devbox01")
    let other = HostID(rawValue: "other001")
    let caller = ControlRouter.Caller(session: UUID(), client: UUID(), kind: .mac)

    init(timing: WorkspaceProviders.Timing = .init(listEvery: .seconds(3600), sshAfter: .seconds(3600), giveUp: .seconds(3600),
                                                     lookEvery: .milliseconds(20), calls: .standard),
         workspaces: [DaemonAPI.WorkspaceInfo] = [
             .init(id: "agents-devbox", name: "agents-devbox", state: "stopped", ssh: "alex@127.0.0.1 -p 2222"),
             .init(id: "scratch-1", name: "scratch-1", state: "running"),
         ]) async throws {
        records = ControlRecords(store: store)
        let settings = try await records.settings { ControlSettings(name: "test", machineID: "m") }
        methods = ControlMethods(records: records, settings: settings, version: "1")
        router = ControlRouter(handler: methods)
        await methods.attach(router)
        home = FileManager.default.temporaryDirectory.appendingPathComponent("providers-\(UUID().uuidString)")
        let provider = StandInProvider(workspaces)
        self.provider = provider
        let sshStarts = self.sshStarts
        providers = WorkspaceProviders(
            store: store, records: records, methods: methods, router: router, secrets: ProviderSecrets(home: home),
            timing: timing,
            hooks: .init(sshStart: { _, destination in sshStarts.add(destination) },
                         hostCommand: { "curl -fsSL https://cp.local/v1/install.sh | sh -s -- 'agents-control:2:h:secret'" },
                         connect: { _, _ in provider }),
            log: { _ in })
        var hooks = ControlMethods.Hooks()
        hooks.workspaces = providers
        await methods.setHooks(hooks)
        for (id, name) in [(devbox, "devbox"), (other, "other")] {
            try await methods.enroll(HostRecord(id: id, name: name))
            await router.know(id)
        }
    }

    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await methods.handle(method: method, params: params, from: caller)
    }

    /// Adds the stand-in as "DigitalOcean", with a secret.
    @discardableResult
    func add() async throws -> ProviderID {
        let added = try await call(DaemonAPI.Method.providersAdd, try JSONValue.encoding(DaemonAPI.ProviderAdd(
            name: "DigitalOcean", kind: .commands, commands: ["preset": "doctl", "tag": "agents"],
            secrets: ["DIGITALOCEAN_TOKEN": "hunter2"])))
        return try added.decode(DaemonAPI.ProviderSummary.self).id
    }

    func link(_ provider: ProviderID, _ host: HostID? = nil, _ workspace: String = "agents-devbox") async throws {
        _ = try await call(DaemonAPI.Method.hostsLink, try JSONValue.encoding(
            DaemonAPI.HostLink(host: host ?? devbox, provider: provider, workspace: workspace)))
    }

    func row(_ host: HostID? = nil) async throws -> DaemonAPI.ControlHost {
        let rows = try await call(DaemonAPI.Method.hostsList).decode([DaemonAPI.ControlHost].self)
        return try #require(rows.first { $0.id == (host ?? devbox) })
    }

    /// Waits for the row to say `state`, for up to `seconds`.
    func waitFor(_ state: String, _ host: HostID? = nil, seconds: Int = 5,
                 where extra: (DaemonAPI.ControlHost) -> Bool = { _ in true }) async throws -> DaemonAPI.ControlHost {
        for _ in 0..<(seconds * 100) {
            let row = try await row(host)
            if row.state == state, extra(row) { return row }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await row(host)
    }
}

@Suite("Workspace providers (#691)")
struct WorkspaceProvidersTests {
    // MARK: Adding (US2)

    @Test func aProviderIsListedWithItsWorkspacesAndNeverItsSecret() async throws {
        let h = try await ProviderHarness()
        let id = try await h.add()
        let listed = try await h.call(DaemonAPI.Method.providersList)["providers"]?.decode([DaemonAPI.ProviderSummary].self)
        let summary = try #require(listed?.first)
        #expect(summary.id == id)
        #expect(summary.name == "DigitalOcean")
        #expect(summary.preset == "doctl")
        #expect(summary.workspaces.map(\.name) == ["agents-devbox", "scratch-1"])
        #expect(summary.secrets == ["DIGITALOCEAN_TOKEN": true])
        #expect(!String(decoding: try JSONEncoder().encode(summary), as: UTF8.self).contains("hunter2"))

        // Not in the store: only in the home's file, which only its user can read (FR-003).
        for key in try await h.store.list(prefix: "") {
            let object = try #require(try await h.store.get(key.key))
            #expect(!String(decoding: object.data, as: UTF8.self).contains("hunter2"), "\(key.key)")
        }
        let file = h.home.appendingPathComponent(ProviderSecrets.fileName)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("hunter2"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func aServerThatIsNotAProviderIsRefusedInItsWords() async throws {
        let h = try await ProviderHarness()
        await h.provider.set(refuse: "It isn’t a workspace provider: it has no workspace_stop tool.")
        await #expect(throws: JSONRPCError(code: JSONRPCError.invalidParams,
                                           message: "It isn’t a workspace provider: it has no workspace_stop tool.")) {
            try await h.add()
        }
        let listed = try await h.call(DaemonAPI.Method.providersList)["providers"]?.arrayValue
        #expect(listed?.isEmpty == true)
    }

    @Test func aProviderWithoutANameIsRefused() async throws {
        let h = try await ProviderHarness()
        await #expect(throws: JSONRPCError(code: JSONRPCError.invalidParams, message: "Give it a name.")) {
            try await h.call(DaemonAPI.Method.providersAdd, try JSONValue.encoding(
                DaemonAPI.ProviderAdd(name: " ", kind: .commands, commands: ["preset": "docker"])))
        }
    }

    @Test func providersAreReadBackAfterARestart() async throws {
        let h = try await ProviderHarness()
        let id = try await h.add()
        let again = WorkspaceProviders(store: h.store, records: h.records, methods: h.methods, router: h.router,
                                       secrets: ProviderSecrets(home: h.home),
                                       hooks: .init(connect: { [provider = h.provider] _, _ in provider }), log: { _ in })
        await again.start()
        #expect(await again.summaries().map(\.id) == [id])
        await again.stop()
    }

    // MARK: Links (US2)

    @Test func aLinkedHostWhoseWorkspaceIsStoppedIsShownStopped() async throws {
        let h = try await ProviderHarness()
        let id = try await h.add()
        try await h.link(id)
        let row = try await h.row()
        #expect(row.state == "stopped")
        #expect(row.workspace?.workspaceName == "agents-devbox")
        #expect(row.workspace?.providerName == "DigitalOcean")
        #expect(row.workspace?.canStart == true)
        #expect(row.workspace?.startWhenUsed == true)
        #expect(row.workspace?.stopWhenIdleMinutes == 30)
        // The link is the host's record, so it is there after a restart.
        #expect(await h.records.host(h.devbox)?.workspace?.workspace == "agents-devbox")
    }

    @Test func linkingAWorkspaceAgainMovesItsLink() async throws {
        let h = try await ProviderHarness()
        let id = try await h.add()
        try await h.link(id)
        try await h.link(id, h.other)
        #expect(await h.records.host(h.devbox)?.workspace == nil)
        #expect(await h.records.host(h.other)?.workspace?.workspace == "agents-devbox")
        #expect(try await h.row().state == "offline")
    }

    @Test func removingAProviderLeavesItsHostsUnlinked() async throws {
        let h = try await ProviderHarness()
        let id = try await h.add()
        try await h.link(id)
        _ = try await h.call(DaemonAPI.Method.providersRemove, try JSONValue.encoding(DaemonAPI.ProviderRequest(id: id)))
        let row = try await h.row()
        #expect(row.workspace == nil)
        #expect(row.state == "offline")
        #expect(await h.records.host(h.devbox) != nil)
        let kept = (try? Data(contentsOf: h.home.appendingPathComponent(ProviderSecrets.fileName))) ?? Data()
        #expect(!String(decoding: kept, as: UTF8.self).contains("hunter2"))
    }

    // MARK: Start and Stop (US1)

    @Test func startShowsEachPhaseUntilTheHostConnects() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let started = try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
            .decode(DaemonAPI.ControlHost.self)
        #expect(started.state == "starting")
        let waiting = try await h.waitFor("starting") { $0.workspace?.phase == "connecting" }
        #expect(waiting.workspace?.phase == "connecting")
        #expect(await h.provider.starts == 1)

        await h.router.setState(.online, of: h.devbox)
        let online = try await h.waitFor("online") { $0.workspace?.phase == nil }
        #expect(online.workspace?.workspaceState == "running")
        #expect(online.workspace?.canStop == true)
        #expect(online.workspace?.problem == nil)
    }

    @Test func aSecondStartJoinsTheFirst() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        await h.provider.set(startTakes: .milliseconds(200))
        for _ in 0..<3 {
            _ = try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        }
        _ = try await h.waitFor("starting") { $0.workspace?.phase == "connecting" }
        #expect(await h.provider.starts == 1)
    }

    @Test func aFailedStartSaysWhyAndOffersStartAgain() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        await h.provider.set(failStart: "Error: droplet is locked")
        _ = try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        let row = try await h.waitFor("stopped") { $0.workspace?.problem != nil }
        #expect(row.workspace?.problem == "Couldn’t start devbox: Error: droplet is locked")
        #expect(row.workspace?.canStart == true)
    }

    @Test func aHostThatDoesNotConnectIsStartedOverSSHThenGivenUp() async throws {
        // Wide apart, so a loaded machine still tries ssh before it gives up.
        let h = try await ProviderHarness(timing: .init(listEvery: .seconds(3600), sshAfter: .milliseconds(100),
                                                        giveUp: .seconds(2), lookEvery: .milliseconds(20),
                                                        calls: .standard))
        try await h.link(try await h.add())
        _ = try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        let row = try await h.waitFor("offline", seconds: 15) { $0.workspace?.problem != nil }
        #expect(h.sshStarts.destinations == ["alex@127.0.0.1 -p 2222"])
        #expect(row.workspace?.problem == "devbox didn’t connect in 2 seconds.")
        #expect(row.workspace?.canStart == false, "the workspace is running: it is agentsd that is down")
    }

    @Test func stopStopsTheWorkspace() async throws {
        let h = try await ProviderHarness()
        let id = try await h.add()
        try await h.link(id, h.devbox, "scratch-1")
        await h.router.setState(.online, of: h.devbox)
        let stopping = try await h.call(DaemonAPI.Method.hostsStop, try JSONValue.encoding(DaemonAPI.HostStop(host: h.devbox)))
            .decode(DaemonAPI.ControlHost.self)
        #expect(stopping.state == "stopping")
        await h.router.setState(.offline(since: Date()), of: h.devbox)
        let stopped = try await h.waitFor("stopped") { $0.workspace?.canStart == true }
        #expect(stopped.workspace?.workspaceState == "stopped")
        #expect(await h.provider.stops == 1)
    }

    @Test func stopWhileStartingIsRefusedNotDropped() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        await h.provider.set(startTakes: .milliseconds(300))
        _ = try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        await #expect(throws: JSONRPCError(code: DaemonAPI.Failure.providerFailed,
                                           message: "devbox is starting. Stop it once it has started.")) {
            try await h.call(DaemonAPI.Method.hostsStop, try JSONValue.encoding(DaemonAPI.HostStop(host: h.devbox)))
        }
        #expect(await h.provider.stops == 0)
    }

    @Test func stopTheMomentAStartedHostIsOnlineIsHeard() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        _ = try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        _ = try await h.waitFor("starting") { $0.workspace?.phase == "connecting" }
        await h.router.setState(.online, of: h.devbox)
        _ = try await h.waitFor("online") { $0.workspace?.phase == nil && $0.workspace?.canStop == true }
        let stopping = try await h.call(DaemonAPI.Method.hostsStop, try JSONValue.encoding(DaemonAPI.HostStop(host: h.devbox)))
            .decode(DaemonAPI.ControlHost.self)
        #expect(stopping.state == "stopping")
        await h.router.setState(.offline(since: Date()), of: h.devbox)
        _ = try await h.waitFor("stopped") { $0.workspace?.canStart == true }
        #expect(await h.provider.stops == 1)
    }

    @Test func anUnlinkedHostCannotBeStarted() async throws {
        let h = try await ProviderHarness()
        await #expect(throws: JSONRPCError(code: DaemonAPI.Failure.notLinked, message: "devbox isn’t linked to a workspace.")) {
            try await h.call(DaemonAPI.Method.hostsStart, try JSONValue.encoding(DaemonAPI.HostRequest(host: h.devbox)))
        }
        #expect(try await h.row().workspace == nil)
    }

    @Test func withoutProvidersTheMethodsSaySo() async throws {
        let records = ControlRecords(store: MemoryStore())
        let settings = try await records.settings { ControlSettings(name: "test", machineID: "m") }
        let methods = ControlMethods(records: records, settings: settings, version: "1")
        await #expect(throws: JSONRPCError(code: DaemonAPI.Failure.providersNeedOneCopy,
                                           message: "Workspace providers need a control plane with one copy, for now.")) {
            try await methods.handle(method: DaemonAPI.Method.providersList, params: [:],
                                     from: .init(session: UUID(), client: UUID(), kind: .mac))
        }
    }
}

@Suite("Reading providers' tools (#691)")
struct ToolMappingTests {
    @Test func theContractsResultsAreRead() throws {
        let content = try ToolMapping.content(of: [
            "content": [["type": "text", "text": "…"]],
            "structuredContent": ["contract": 1, "workspaces": [
                ["id": "a", "name": "devbox", "state": "stopped", "ssh": "alex@h -p 2222", "tunnel": true, "cost": "$1"],
                ["id": "b", "name": "odd", "state": "hibernating"],
                ["name": "no id"],
            ]],
        ])
        let workspaces = ToolMapping.contract.workspaces(content)
        #expect(workspaces == [
            .init(id: "a", name: "devbox", state: "stopped", ssh: "alex@h -p 2222", tunnel: true, cost: "$1"),
            .init(id: "b", name: "odd", state: "unknown"),
        ])
    }

    @Test func anErrorIsTheProvidersOwnWords() {
        #expect(throws: ProviderFailure("Error: droplet is locked")) {
            try ToolMapping.content(of: ["content": [["type": "text", "text": "Error: droplet is locked\n"]], "isError": true])
        }
    }

    @Test func aMapReadsAnotherServersTools() throws {
        let map = try ToolMapping.map([
            "list": ["tool": "droplet-list", "arguments": ["tag_name": "agents"], "items": "droplets[]",
                     "id": "id", "name": "name", "state": "status", "ssh": "root@{networks.v4[0].ip_address}",
                     "states": ["active": "running", "off": "stopped"]],
            "start": ["tool": "droplet-actions-power-on", "arguments": ["droplet_id": "{id}"]],
            "stop": ["tool": "droplet-actions-power-off", "arguments": ["droplet_id": "{id}"]],
        ])
        #expect(map.missing(from: ["droplet-list", "droplet-actions-power-on"]) == "droplet-actions-power-off")
        #expect(map.missing(from: ["droplet-list", "droplet-actions-power-on", "droplet-actions-power-off"]) == nil)
        #expect(map.arguments(map.start, id: "4101") == ["droplet_id": "4101"])
        let found = map.workspaces([
            "droplets": [
                ["id": 4101, "name": "devbox", "status": "off", "networks": ["v4": [["ip_address": "203.0.113.7"]]]],
                ["id": 4102, "name": "build", "status": "active", "networks": ["v4": []]],
            ],
        ])
        #expect(found == [
            .init(id: "4101", name: "devbox", state: "stopped", ssh: "root@203.0.113.7"),
            .init(id: "4102", name: "build", state: "running"),
        ])
    }

    @Test func aMapMissingWhatItNeedsIsRefused() {
        #expect(throws: ProviderFailure("The tool map has no stop.tool.")) {
            try ToolMapping.map(["list": ["tool": "l", "id": "id", "name": "n", "state": "s"], "start": ["tool": "s"]])
        }
        #expect(throws: ProviderFailure("The tool map has no list.state.")) {
            try ToolMapping.map(["list": ["tool": "l", "id": "id", "name": "n"], "start": ["tool": "s"], "stop": ["tool": "t"]])
        }
    }

    @Test func anSSHDestinationWithAPortBecomesOneWord() {
        #expect(WorkspaceProviders.sshDestination("alex@127.0.0.1 -p 2222") == "ssh://alex@127.0.0.1:2222")
        #expect(WorkspaceProviders.sshDestination("devstack-1.cws") == "devstack-1.cws")
    }

    @Test func aHostRecordFromBeforeHasNoWorkspace() throws {
        let old = #"{"id":"devbox01","name":"devbox","reach":{"dialOut":{}},"platform":"","version":"","installed":false,"rev":1}"#
        let record = try ControlRecords.decoder.decode(HostRecord.self, from: Data(old.utf8))
        #expect(record.workspace == nil)
    }

    @Test func aRecordsSecretsAreChecked() {
        var record = ProviderRecord(id: .init(rawValue: "x"), name: "Coder", kind: .http, url: "https://coder.example/mcp",
                                    headers: ["Authorization": "Bearer ${CODER_TOKEN}"])
        #expect(record.problem == "${CODER_TOKEN} isn’t one of its secrets.")
        record.secretNames = ["CODER_TOKEN"]
        #expect(record.problem == nil)
        record.url = "coder.example"
        #expect(record.problem == "The address must start with http:// or https://.")
    }

    @Test func anHTTPProvidersSecretGoesInItsHeaders() throws {
        let record = ProviderRecord(id: .init(rawValue: "x"), name: "Coder", kind: .http, url: "https://coder.example/mcp",
                                    headers: ["Authorization": "Bearer ${CODER_TOKEN}"], secretNames: ["CODER_TOKEN"])
        let server = try ProviderConnection.server(for: record, secrets: ["CODER_TOKEN": "t0k"], commandProvider: nil)
        #expect(server.transport == .http(url: "https://coder.example/mcp", headers: ["Authorization": "Bearer t0k"]))
        #expect(throws: ProviderFailure("workspace-commands isn’t installed beside the control plane.")) {
            try ProviderConnection.server(for: ProviderRecord(id: .init(rawValue: "y"), name: "d", kind: .commands,
                                                               commands: ["preset": "docker"]),
                                          secrets: [:], commandProvider: nil)
        }
    }
}

/// The real command provider, end to end over stdio, when a build of it is named
/// (`AGENTS_WORKSPACE_COMMANDS`, as the quickstart's walk sets it).
@Suite("The command provider over stdio (#691)",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WORKSPACE_COMMANDS"] != nil))
struct CommandProviderStdioTests {
    @Test func startsAWorkspaceThroughTheBinary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("up").path
        let record = ProviderRecord(id: .init(rawValue: "local"), name: "Local", kind: .commands, commands: [
            "workspaces": [["name": "devbox", "start": .string("touch '\(marker)'"), "stop": .string("rm -f '\(marker)'"),
                            "status": .string("test -e '\(marker)' && echo running || echo stopped")]],
        ])
        let connection = try ProviderConnection(record: record, secrets: [:], cwd: folder, log: { _ in })
        let checked = try await connection.check()
        #expect(checked.workspaces.map(\.state) == ["stopped"])
        let started = try await connection.start("devbox")
        #expect(started?.state == "running")
        await connection.end()
    }
}
