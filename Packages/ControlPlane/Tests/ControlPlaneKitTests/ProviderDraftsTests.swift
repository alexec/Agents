import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// Write It for Me (#858): a draft of a tool map or commands, written by an agent on the
// control plane's own host. The agent is a stand-in here: the test calls its tools as the
// daemon would relay them, and sees what the sheet is told.

/// What the stand-in server and CLI did, and what the sheet was told.
final class DraftWorld: @unchecked Sendable {
    private let lock = NSLock()
    var tools: [JSONValue]
    var workspaces: [DaemonAPI.WorkspaceInfo] = [
        .init(id: "101", name: "agents-devbox", state: "running", cost: "$0.03/hour"),
        .init(id: "102", name: "scratch-1", state: "stopped"),
    ]
    /// Thrown by every check, when set: the server's own words.
    var checkFails: String?
    var helps: [String: String] = [:]
    var notInstalled = false
    /// When set, the list's items as the server gave them, none of which the map reads.
    var unread: [JSONValue]?
    /// When set, the first item a check shows, though the map reads every item (#975).
    var firstItem: JSONValue?
    /// What `ssh -G` prints; nil is ssh failing.
    var sshConfig: String? = "hostname cws.devstack-1\nuser coder\nport 22\nproxycommand ssh -W %h:%p bastion.cws.example\nproxyjump none\n"
    private var _sshAsked: [String] = []
    var sshAsked: [String] { lock.withLock { _sshAsked } }
    func askedSSH(_ destination: String) -> ProviderDrafts.Help {
        lock.withLock { _sshAsked.append(destination) }
        return sshConfig.map { .init(status: 0, text: $0) } ?? .init(status: 255, text: "ssh: Could not resolve hostname")
    }

    private var _checks = 0, _starts = 0, _stops = 0, _helpRuns: [[String]] = [], _updates: [DaemonAPI.ProviderDraftUpdate] = []
    private var _started: [DaemonAPI.StartRequest] = [], _stopped: [UUID] = [], _logs: [String] = []
    var ownerHere = true
    private var _ownerAsked = 0
    /// How many ticks have asked whether the sheet is still there.
    var ownerAsked: Int { lock.withLock { _ownerAsked } }
    func askOwner() -> Bool { lock.withLock { _ownerAsked += 1 }; return ownerHere }
    let agent = UUID()

    init(tools: [String], descriptions: [String: String] = [:]) {
        self.tools = tools.map { name in
            ["name": .string(name), "description": .string(descriptions[name] ?? "Does \(name)."),
             "inputSchema": ["type": "object"]]
        }
    }

    var checks: Int { lock.withLock { _checks } }
    var starts: Int { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var helpRuns: [[String]] { lock.withLock { _helpRuns } }
    var updates: [DaemonAPI.ProviderDraftUpdate] { lock.withLock { _updates } }
    var started: [DaemonAPI.StartRequest] { lock.withLock { _started } }
    var stopped: [UUID] { lock.withLock { _stopped } }
    var logs: [String] { lock.withLock { _logs } }
    var last: DaemonAPI.ProviderDraftUpdate? { updates.last }

    func checked() { lock.withLock { _checks += 1 } }
    func startedOne() { lock.withLock { _starts += 1 } }
    func stoppedOne() { lock.withLock { _stops += 1 } }
    func ranHelp(_ words: [String]) { lock.withLock { _helpRuns.append(words) } }
    func told(_ update: DaemonAPI.ProviderDraftUpdate) { lock.withLock { _updates.append(update) } }
    func startedAgent(_ request: DaemonAPI.StartRequest) { lock.withLock { _started.append(request) } }
    func stoppedAgent(_ id: UUID) { lock.withLock { _stopped.append(id) } }
    func logged(_ line: String) { lock.withLock { _logs.append(line) } }
}

/// The drafts' clock, which moves only when the test moves it (#891).
final class DraftClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { _now } }
    func advance(by duration: Duration) { lock.withLock { _now += duration } }
}

/// One connection to the stand-in server, as a record (with its draft map) says.
struct DraftServer: WorkspaceProvider {
    let world: DraftWorld
    let record: ProviderRecord

    func tools() async throws -> [JSONValue] { world.tools }

    func check() async throws -> ProviderConnection.Checked {
        world.checked()
        if let fails = world.checkFails { throw ProviderFailure(fails) }
        if let map = record.map {
            let mapping = try ToolMapping.map(map)
            if let missing = mapping.missing(from: world.tools.compactMap { $0["name"]?.stringValue }) {
                throw ProviderFailure("The tool map names \(missing), which the server doesn’t have.")
            }
        }
        if let unread = world.unread { return .init(workspaces: [], items: unread.count, firstItem: unread.first) }
        return .init(workspaces: world.workspaces, items: world.firstItem == nil ? nil : world.workspaces.count,
                     firstItem: world.firstItem)
    }

    func list() async throws -> [DaemonAPI.WorkspaceInfo] { world.workspaces }
    func start(_ id: String) async throws -> DaemonAPI.WorkspaceInfo? {
        world.startedOne()
        return world.workspaces.first { $0.id == id }.map { var w = $0; w.state = "running"; return w }
    }
    func stop(_ id: String) async throws -> DaemonAPI.WorkspaceInfo? {
        world.stoppedOne()
        return nil
    }
    func end() async {}
}

struct DraftHarness {
    let world: DraftWorld
    let drafts: ProviderDrafts
    let host = HostID(rawValue: "thismac1")
    let owner = ControlRouter.Caller(session: UUID(), client: UUID(), kind: .mac)

    init(world: DraftWorld, timing: ProviderDrafts.Timing = .init(total: .seconds(300), answer: .seconds(120), lastWord: .seconds(60),
                                                                   ownerGone: .seconds(30), keptAfter: .seconds(600),
                                                                   tick: .milliseconds(20), help: .seconds(25)),
         localHost: Bool = true, busy: String? = nil, clock: DraftClock? = nil) {
        self.world = world
        let host = self.host
        drafts = ProviderDrafts(timing: timing, hooks: .init(
            connect: { record, _ in DraftServer(world: world, record: record) },
            help: { _, words, _ in
                world.ranHelp(words)
                if world.notInstalled { return .init(status: 127, text: "env: cws: No such file or directory") }
                return .init(status: 0, text: world.helps[words.joined(separator: " ")] ?? "")
            },
            localHost: { localHost ? .init(id: host, name: "This Mac") : nil },
            startAgent: { _, request, _ in
                world.startedAgent(request)
                return world.agent
            },
            stopAgent: { _, agent, _ in world.stoppedAgent(agent) },
            notify: { _, update in
                world.told(update)
                return true
            },
            ownerHere: { _ in world.askOwner() },
            busyHost: { _, _ in busy },
            sshConfig: { world.askedSSH($0) }),
            log: { world.logged($0) },
            now: { clock?.now ?? .now })
    }

    static let mapForm = DaemonAPI.ProviderAdd(name: "DigitalOcean", kind: .stdio, command: "npx", args: ["-y", "@digitalocean/mcp"])

    func start(_ form: DaemonAPI.ProviderAdd = DraftHarness.mapForm, secrets: [String: String] = ["DIGITALOCEAN_API_TOKEN": "dop_v1_supersecretvalue"],
               runtime: String = "claude") async throws -> DaemonAPI.ProviderDraftStarted {
        try await drafts.start(.init(form: form, secrets: secrets, runtimeID: runtime), from: owner)
    }

    /// One of the writer's tools, as the daemon relays it: its words.
    func tool(_ draft: UUID, _ name: String, _ arguments: JSONValue = [:], agent: UUID? = nil, from: HostID? = nil) async throws -> String {
        let answer = try await drafts.call(from: from ?? host, .init(agentID: agent ?? world.agent, draft: draft, tool: name, arguments: arguments))
        return answer["note"]?.stringValue ?? ""
    }

    /// goodMap, with `ssh` as list.ssh (#975).
    static func map(ssh: String) -> JSONValue {
        ["list": ["tool": "droplet-list", "items": "droplets", "id": "id", "name": "name", "state": "status", "ssh": .string(ssh)],
         "start": ["tool": "droplet-power-on", "arguments": ["droplet_id": "{id}"]],
         "stop": ["tool": "droplet-power-off", "arguments": ["droplet_id": "{id}"]]]
    }

    static let goodMap: JSONValue = [
        "list": ["tool": "droplet-list", "items": "droplets", "id": "id", "name": "name", "state": "status"],
        "start": ["tool": "droplet-power-on", "arguments": ["droplet_id": "{id}"]],
        "stop": ["tool": "droplet-power-off", "arguments": ["droplet_id": "{id}"]],
    ]
}

@Suite("Write It for Me: a tool map (#858 US1)")
struct ProviderDraftMapTests {
    @Test("A server that doesn't follow the contract starts a writer with its tools, on this machine's host")
    func startsAWriter() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        let harness = DraftHarness(world: world)
        let started = try await harness.start()
        #expect(started.answered == nil)
        let request = try #require(world.started.first)
        #expect(request.purpose == .providerDraft(id: started.draft))
        #expect(request.runtimeID == "claude")
        #expect(request.prompt.contains("droplet-power-on"))
        #expect(request.prompt.contains("DIGITALOCEAN_API_TOKEN"))
        #expect(world.last?.state == "writing")
        #expect(world.last?.steps.first?.text == "read 3 tools")
    }

    @Test("A server that follows the contract, or that the shipped map fits, needs no agent")
    func cheapAnswers() async throws {
        let contract = DraftWorld(tools: ToolMapping.required)
        let answered = try await DraftHarness(world: contract).start()
        #expect(answered.answered?.note == "It follows the contract: it needs no map.")
        #expect(contract.started.isEmpty)

        let digitalOcean = DraftWorld(tools: ["droplet-list", "power-on-droplet", "power-off-droplet", "droplet-delete"])
        let shipped = try await DraftHarness(world: digitalOcean).start()
        #expect(shipped.answered?.map == ShippedToolMaps.digitalOcean)
        #expect(shipped.answered?.note == "Agents ships this map.")
        #expect(digitalOcean.started.isEmpty)
    }

    @Test("No host on this machine refuses, with the reason")
    func noLocalHost() async throws {
        let world = DraftWorld(tools: ["droplet-list"])
        await #expect(throws: JSONRPCError.self) { try await DraftHarness(world: world, localHost: false).start() }
        let runtimes = await DraftHarness(world: world, localHost: false).drafts.runtimes()
        #expect(runtimes.runtimes.isEmpty)
        #expect(runtimes.why == "No host runs where the control plane runs, so no agent can write here.")
    }

    @Test("A runtime that can't turn its own tools off isn't offered and is refused")
    func onlyWriterRuntimes() async throws {
        let world = DraftWorld(tools: ["droplet-list"])
        let harness = DraftHarness(world: world)
        let runtimes = await harness.drafts.runtimes()
        #expect(runtimes.runtimes.map(\.id) == ["claude"])
        #expect(runtimes.runtimes.first?.isDefault == true)
        await #expect(throws: JSONRPCError.self) { try await harness.start(runtime: "copilot") }
        #expect(world.started.isEmpty)
    }

    @Test("check_draft checks with one list; send_draft ends it done, and its map is the result")
    func checkAndSend() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        let wrong: JSONValue = ["list": ["tool": "list-droplets", "items": "", "id": "id", "name": "name", "state": "status"],
                                "start": ["tool": "x"], "stop": ["tool": "y"]]
        #expect(try await harness.tool(id, AppTool.checkDraft, ["draft": wrong]).hasPrefix("Failed: The tool map names list-droplets"))
        let passed = try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap])
        #expect(passed.hasPrefix("Passed: listed 2."))
        #expect(passed.contains("agents-devbox (id 101): running"))
        #expect(world.last?.check?.passed == true)
        #expect(world.checks == 2)
        #expect(try await harness.tool(id, AppTool.sendDraft, ["draft": DraftHarness.goodMap, "note": "I didn't try start."])
                    == "Sent. End your turn now.")
        #expect(world.last?.state == "done")
        #expect(world.last?.draftJSON == DraftHarness.goodMap)
        #expect(world.last?.note == "I didn't try start.")
        #expect(await harness.drafts.result(id)?.json == DraftHarness.goodMap)
        try await eventually { world.stopped == [world.agent] }
        // Ended: the tools say so.
        #expect(try await harness.tool(id, AppTool.readTools) == "This draft has ended.")
    }

    @Test("A check that reads none of the items says so and shows the first, redacted")
    func checkShowsAnItemTheMapMissed() async throws {
        let secret = "dop_v1_supersecretvalue"
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        world.unread = [["uid": "m-101", "label": "devbox", "token": .string(secret)], ["uid": "m-102", "label": "scratch-1"]]
        let harness = DraftHarness(world: world)
        let id = try await harness.start(secrets: ["DIGITALOCEAN_API_TOKEN": secret]).draft
        let answer = try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap])
        #expect(answer.hasPrefix("Passed: listed 0."))
        #expect(answer.contains("2 of the 2 items at list.items have no id or name by this map. The first item:"))
        #expect(answer.contains(#""label":"devbox""#))
        #expect(!answer.contains(secret))
        #expect(answer.contains("${DIGITALOCEAN_API_TOKEN}"))
    }

    @Test("A check of a map with no ssh says so, shows the first item, and the sheet is told (#975)")
    func checkSaysThereIsNoSSH() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        world.firstItem = ["name": "devstack-1", "tools": ["IDEs": [["accessUrl": "vscode://vscode-remote/ssh-remote+coder@cws.devstack-1/home"]]]]
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        let answer = try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap])
        #expect(answer.contains("No workspace has an ssh destination, so none can be added as a host."))
        #expect(answer.contains("ssh-remote+"))
        #expect(answer.contains("coder@cws.devstack-1/home"))
        #expect(world.last?.check?.noSSH == true)
        #expect(world.last?.check?.ssh == nil)
        #expect(world.sshAsked.isEmpty)
        #expect(world.last?.steps.last?.text == "no ssh destination")
    }

    @Test("A check of a map with ssh tests one destination with ssh -G and says what it resolved to (#975)")
    func checkResolvesSSH() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        world.workspaces = [.init(id: "d1", name: "devstack-1", state: "running", ssh: "coder@cws.devstack-1"),
                            .init(id: "d2", name: "devstack-2", state: "stopped", ssh: "coder@cws.devstack-2")]
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        let map = DraftHarness.map(ssh: "coder@cws.{name}")
        let answer = try await harness.tool(id, AppTool.checkDraft, ["draft": map])
        let words = "ssh -G coder@cws.devstack-1: hostname cws.devstack-1, user coder, port 22, ProxyCommand ssh -W %h:%p bastion.cws.example"
        #expect(answer.contains(words))
        #expect(!answer.contains("No workspace has an ssh destination"))
        #expect(world.sshAsked == ["coder@cws.devstack-1"])
        #expect(world.last?.check?.ssh == words)
        #expect(world.last?.check?.noSSH == nil)

        world.sshConfig = nil
        let failed = try await harness.tool(id, AppTool.checkDraft, ["draft": map])
        #expect(failed.contains("ssh -G coder@cws.devstack-1 failed: ssh: Could not resolve hostname. Check the destination."))
    }

    @Test("The prompt tells the writer where an ssh destination hides, and an ssh with a port is tested as one word (#975)")
    func promptAndPort() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        world.workspaces = [.init(id: "d1", name: "box", state: "running", ssh: "alex@127.0.0.1 -p 2222")]
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        let prompt = try #require(world.started.first?.prompt)
        #expect(prompt.contains("ssh-remote+coder@host"))
        #expect(prompt.contains("program=ssh"))
        #expect(prompt.contains("ssh -G"))
        let map = DraftHarness.map(ssh: "alex@127.0.0.1 -p 2222")
        _ = try await harness.tool(id, AppTool.checkDraft, ["draft": map])
        #expect(world.sshAsked == ["ssh://alex@127.0.0.1:2222"])
    }

    @Test("Whether a draft names ssh: a map's list.ssh, a config's, a workspace's or a preset's (#975)")
    func hasSSH() {
        #expect(!ProviderDrafts.hasSSH(DraftHarness.goodMap, commands: false))
        #expect(ProviderDrafts.hasSSH(["list": ["ssh": "coder@cws.{name}"]], commands: false))
        #expect(!ProviderDrafts.hasSSH(["list": "cws list", "columns": ["id"]], commands: true))
        #expect(ProviderDrafts.hasSSH(["list": "cws list", "columns": ["id"], "ssh": "root@${ip}"], commands: true))
        #expect(ProviderDrafts.hasSSH(["workspaces": [["id": "a"], ["id": "b", "ssh": "b.cws"]]], commands: true))
        #expect(ProviderDrafts.hasSSH(["preset": "coder"], commands: true))
    }

    @Test("A map's check against a real server counts the items it missed, and names the keys when it finds no list")
    func checkAgainstTheWalkServer() async throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/walk858-mcp.py").path
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("w858-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func connection(items: String, name: String) throws -> ProviderConnection {
            let map: JSONValue = ["list": ["tool": "machines-get", "items": .string(items), "id": "uid", "name": .string(name), "state": "power"],
                                  "start": ["tool": "machine-on", "arguments": ["uid": "{id}"]],
                                  "stop": ["tool": "machine-off", "arguments": ["uid": "{id}"]]]
            return try ProviderConnection(record: ProviderRecord(id: .init(rawValue: "w858"), name: "Machines", kind: .stdio,
                                                                 command: "/usr/bin/env", args: ["python3", script], map: map),
                                          secrets: ["TEST_TOKEN": "t0k"], cwd: folder, log: { _ in })
        }
        let missed = try connection(items: "machines", name: "name")
        let checked = try await missed.check()
        await missed.end()
        #expect(checked.workspaces.isEmpty)
        #expect(checked.items == 2)
        #expect(checked.firstItem?["label"]?.stringValue == "devbox")
        let read = try connection(items: "machines", name: "label")
        #expect(try await read.check().workspaces.map(\.name) == ["devbox", "scratch-1"])
        await read.end()
        let none = try connection(items: "nodes", name: "label")
        await #expect(throws: ProviderFailure("The tool map’s list.items finds no list in what machines-get answered. Its answer has the keys machines.")) {
            try await none.check()
        }
        await none.end()
    }

    @Test("Another agent's call is refused (FR-011)")
    func onlyItsAgent() async throws {
        let world = DraftWorld(tools: ["droplet-list"])
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        await #expect(throws: JSONRPCError.self) { try await harness.tool(id, AppTool.readTools, agent: UUID()) }
        await #expect(throws: JSONRPCError.self) { try await harness.tool(id, AppTool.readTools, from: HostID(rawValue: "otherhost")) }
        await #expect(throws: JSONRPCError.self) { try await harness.tool(UUID(), AppTool.readTools) }
        #expect(try await harness.tool(id, AppTool.readTools).contains("droplet-list"))
    }

    @Test("After 8 checks every tool but send_draft and give_up says the time is over (FR-017)")
    func eightChecks() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        for _ in 0..<ProviderDrafts.maxChecks {
            #expect(try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap]).hasPrefix("Passed"))
        }
        #expect(try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap]) == ProviderDrafts.overWords)
        #expect(try await harness.tool(id, AppTool.readTools) == ProviderDrafts.overWords)
        #expect(world.checks == ProviderDrafts.maxChecks)
        #expect(try await harness.tool(id, AppTool.giveUp, ["reason": "It has no list."]) == "Ended.")
        #expect(world.last?.state == "failed")
        #expect(world.last?.note == "It has no list.")
    }

    @Test("Out of time with a passed draft: that draft is the result")
    func outOfTime() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        // The drafts' clock moves only once the draft has passed (#891), so a slow runner can't end it first.
        let clock = DraftClock()
        let harness = DraftHarness(world: world, timing: .init(total: .milliseconds(150), answer: .seconds(5), lastWord: .milliseconds(100),
                                                               ownerGone: .seconds(30), keptAfter: .seconds(600),
                                                               tick: .milliseconds(10), help: .seconds(25)),
                                   clock: clock)
        let id = try await harness.start().draft
        #expect(try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap]).hasPrefix("Passed"))
        for _ in 0..<500 where !["done", "failed", "cancelled"].contains(world.last?.state ?? "") {
            clock.advance(by: .milliseconds(50))
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(world.last?.state == "done")
        #expect(world.last?.draftJSON == DraftHarness.goodMap)
    }

    @Test("Cancel, or the sheet going for good, stops the agent and drops the draft")
    func cancel() async throws {
        let world = DraftWorld(tools: ["droplet-list"])
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        await harness.drafts.cancel(id, from: harness.owner)
        #expect(world.last?.state == "cancelled")
        try await eventually { world.stopped == [world.agent] }
        #expect(await harness.drafts.result(id) == nil)

        // The sheet gone: on the drafts' clock, which only the test moves (#912), so a slow
        // machine can't end it early or late. Once a tick has seen the owner gone, the clock
        // moves past ownerGone, and the next tick cancels.
        let gone = DraftWorld(tools: ["droplet-list"])
        let clock = DraftClock()
        let quick = DraftHarness(world: gone, timing: .init(total: .seconds(300), answer: .seconds(120), lastWord: .seconds(60),
                                                            ownerGone: .seconds(30), keptAfter: .seconds(600),
                                                            tick: .milliseconds(10), help: .seconds(25)),
                                 clock: clock)
        _ = try await quick.start()
        gone.ownerHere = false
        let asked = gone.ownerAsked
        try await eventually { gone.ownerAsked > asked }
        #expect(gone.last?.state != "cancelled")
        clock.advance(by: .seconds(31))
        try await eventually { gone.last?.state == "cancelled" }
        #expect(gone.stopped == [gone.agent])
    }

    @Test("A turn that ends with no draft fails, saying so")
    func endsWithNoDraft() async throws {
        let world = DraftWorld(tools: ["droplet-list"])
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        _ = try await harness.tool(id, "turn_ended")
        #expect(world.last?.state == "failed")
        #expect(world.last?.note == "It ended without sending a map.")
    }

    @Test("No secret's value reaches the agent, a step, an update or the log (FR-022, FR-024, SC-003)")
    func secretsStayHere() async throws {
        let secret = "dop_v1_supersecretvalue"
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"],
                               descriptions: ["droplet-list": "Lists droplets. Token: \(secret)"])
        world.checkFails = "401 Unauthorized for token \(secret) (\(Data(secret.utf8).base64EncodedString()))"
        world.workspaces = [.init(id: "1", name: "box-\(secret)", state: "running")]
        let harness = DraftHarness(world: world)
        let id = try await harness.start(secrets: ["DIGITALOCEAN_API_TOKEN": secret]).draft
        var seen = [try #require(world.started.first).prompt]
        seen.append(try await harness.tool(id, AppTool.readTools))
        seen.append(try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap]))
        world.checkFails = nil
        seen.append(try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap]))
        let encoded = try JSONEncoder().encode(world.updates)
        seen.append(String(decoding: encoded, as: UTF8.self))
        seen += world.logs
        for text in seen {
            #expect(!text.contains(secret))
            #expect(!text.contains(Data(secret.utf8).base64EncodedString()))
        }
        #expect(seen[1].contains("${DIGITALOCEAN_API_TOKEN}"))
        #expect(seen[2].contains("${DIGITALOCEAN_API_TOKEN}"))
    }

    @Test("A list that may change something is asked first; a no runs nothing (FR-013)")
    func unsafeListIsAsked() async throws {
        let world = DraftWorld(tools: ["droplet-power-on", "droplet-power-off"])
        let harness = DraftHarness(world: world)
        let id = try await harness.start().draft
        let unsafe: JSONValue = ["list": ["tool": "droplet-power-on", "items": "", "id": "id", "name": "name", "state": "s"],
                                 "start": ["tool": "droplet-power-on"], "stop": ["tool": "droplet-power-off"]]
        async let answer = harness.tool(id, AppTool.checkDraft, ["draft": unsafe])
        let question = try await waitForQuestion(world)
        #expect(question.kind == .check)
        #expect(question.yes == "Run Check")
        try await harness.drafts.answer(.init(draft: id, question: question.id, yes: false), from: harness.owner)
        #expect(try await answer.hasPrefix("The person said no to this check"))
        #expect(world.checks == 0)
    }

    @Test("prove_start: nothing without a yes, one start with it; no answer in time is a no (US3, SC-004)")
    func proveStart() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        let harness = DraftHarness(world: world, timing: .init(total: .seconds(300), answer: .milliseconds(100), lastWord: .seconds(5),
                                                               ownerGone: .seconds(30), keptAfter: .seconds(600),
                                                               tick: .milliseconds(10), help: .seconds(25)))
        let id = try await harness.start().draft
        #expect(try await harness.tool(id, AppTool.proveStart, ["draft": DraftHarness.goodMap, "workspace": "scratch-1"])
                    .contains("isn’t in the last list"))
        _ = try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap])
        // No answer: a no.
        #expect(try await harness.tool(id, AppTool.proveStart, ["draft": DraftHarness.goodMap, "workspace": "scratch-1"])
                    == "The person said no.")
        #expect(world.starts == 0)
        // A yes: one start.
        async let started = harness.tool(id, AppTool.proveStart, ["draft": DraftHarness.goodMap, "workspace": "agents-devbox"])
        let question = try await waitForQuestion(world)
        #expect(question.text == "Claude wants to start agents-devbox on DigitalOcean to prove the map. $0.03/hour while running. It stays running until you stop it.")
        #expect(question.yes == "Start It")
        try await harness.drafts.answer(.init(draft: id, question: question.id, yes: true), from: harness.owner)
        #expect(try await started == "Started agents-devbox: running")
        #expect(world.starts == 1)
    }

    @Test("A stop of a workspace whose host has agents working isn't asked (FR-020)")
    func busyStop() async throws {
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        let harness = DraftHarness(world: world, busy: "devbox")
        let id = try await harness.start().draft
        _ = try await harness.tool(id, AppTool.checkDraft, ["draft": DraftHarness.goodMap])
        #expect(try await harness.tool(id, AppTool.proveStop, ["draft": DraftHarness.goodMap, "workspace": "101"])
                    == "Not asked: agents are working on devbox.")
        #expect(world.stops == 0)
    }

    func eventually(_ what: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !what() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(what())
    }

    /// The question the sheet was last told, once there is one.
    func waitForQuestion(_ world: DraftWorld) async throws -> DaemonAPI.DraftQuestion {
        for _ in 0..<200 {
            if let question = world.last?.question { return question }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProviderFailure("No question was asked.")
    }
}

@Suite("Write It for Me: commands for a CLI (#858 US2)")
struct ProviderDraftCommandsTests {
    static let form = DaemonAPI.ProviderAdd(name: "Company workspaces", kind: .commands, cli: "cws")

    func world() -> DraftWorld {
        let world = DraftWorld(tools: [])
        world.helps = ["": "Usage: cws <command>\n  list    List workspaces\n  start   Start one\n  stop    Stop one\n  destroy Delete one",
                       "list": "Usage: cws list [--no-header]"]
        return world
    }

    @Test("A preset's CLI, or one not installed, starts no agent")
    func cheapAnswers() async throws {
        let world = world()
        let preset = try await DraftHarness(world: world).start(.init(name: "D", kind: .commands, cli: "doctl"), secrets: [:])
        #expect(preset.answered?.preset == "doctl")
        #expect(preset.answered?.note == "Agents has a preset for doctl: use DigitalOcean Droplets.")
        #expect(world.started.isEmpty)
        world.notInstalled = true
        await #expect(throws: JSONRPCError.self) { try await DraftHarness(world: world).start(Self.form, secrets: [:]) }
        #expect(world.started.isEmpty)
    }

    @Test("read_help runs only `cws <words> --help`, for words the help printed")
    func readHelp() async throws {
        let world = world()
        let harness = DraftHarness(world: world)
        let id = try await harness.start(Self.form, secrets: [:]).draft
        #expect(try #require(world.started.first).prompt.contains("list    List workspaces"))
        #expect(try await harness.tool(id, AppTool.readHelp, ["words": ["list"]]) == "Usage: cws list [--no-header]")
        #expect(try await harness.tool(id, AppTool.readHelp, ["words": ["-y", "list"]]).hasPrefix("Not run: “-y” is a flag"))
        #expect(try await harness.tool(id, AppTool.readHelp, ["words": ["destroy"]]).hasPrefix("Not run: “destroy” may change"))
        #expect(try await harness.tool(id, AppTool.readHelp, ["words": ["list; rm"]]).hasPrefix("Not run:"))
        #expect(try await harness.tool(id, AppTool.readHelp, ["words": ["reboot-all"]]).hasPrefix("Not run:"))
        #expect(world.helpRuns == [[], ["list"]])
    }

    @Test("A safe list is checked at once; one that isn't is asked")
    func checks() async throws {
        let world = world()
        let harness = DraftHarness(world: world)
        let id = try await harness.start(Self.form, secrets: [:]).draft
        let safe: JSONValue = ["list": "cws list --no-header", "columns": ["id", "name", "state"],
                               "start": "cws start ${id}", "stop": "cws stop ${id}"]
        #expect(try await harness.tool(id, AppTool.checkDraft, ["draft": safe]).hasPrefix("Passed: listed 2."))
        let unsafe: JSONValue = ["list": "cws list | sh", "columns": ["id", "name", "state"], "start": "x", "stop": "y"]
        async let answer = harness.tool(id, AppTool.checkDraft, ["draft": unsafe])
        let question = try await ProviderDraftMapTests().waitForQuestion(world)
        #expect(question.text.contains("It isn’t on the safe list because `cws list | sh` has “|”"))
        try await harness.drafts.answer(.init(draft: id, question: question.id, yes: true), from: harness.owner)
        #expect(try await answer.hasPrefix("Passed"))
        #expect(world.checks == 2)
    }
}

@Suite("Write It for Me: what Add keeps (#858 FR-005)")
struct ProviderDraftAddTests {
    @Test("Add with the draft's own map marks it written by the runtime; a changed map doesn't")
    func writtenBy() async throws {
        let harness = try await ProviderHarness()
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        let draftHarness = DraftHarness(world: world)
        await harness.providers.draft(with: draftHarness.drafts)
        let id = try await draftHarness.start().draft
        _ = try await draftHarness.tool(id, AppTool.sendDraft, ["draft": DraftHarness.goodMap])

        // Pretty-printed again by the sheet: the same JSON, so the same map.
        let pretty = try JSONEncoder().encode(DraftHarness.goodMap)
        let same = try JSONValue.parse(pretty)
        var add = DaemonAPI.ProviderAdd(name: "Droplets", kind: .stdio, command: "npx", map: same, draft: id)
        let kept = try await harness.call(DaemonAPI.Method.providersAdd, try JSONValue.encoding(add)).decode(DaemonAPI.ProviderSummary.self)
        let record = try await self.record(kept.id, in: harness)
        #expect(record.writtenBy?.runtimeID == "claude")
        #expect(record.map == DraftHarness.goodMap)

        var object = try #require(DraftHarness.goodMap.objectValue)
        object["list"] = ["tool": "droplet-list", "items": "droplets", "id": "id", "name": "name", "state": "state"]
        let changed = JSONValue.object(object)
        add = DaemonAPI.ProviderAdd(name: "Droplets 2", kind: .stdio, command: "npx", map: changed, draft: id)
        let other = try await harness.call(DaemonAPI.Method.providersAdd, try JSONValue.encoding(add)).decode(DaemonAPI.ProviderSummary.self)
        #expect(try await self.record(other.id, in: harness).writtenBy == nil)
    }

    func record(_ id: ProviderID, in harness: ProviderHarness) async throws -> ProviderRecord {
        let object = try #require(try await harness.store.get(WorkspaceProviders.key(id)))
        return try ControlRecords.decoder.decode(ProviderRecord.self, from: object.data)
    }

    @Test("A record kept before #858 reads with no writtenBy")
    func oldRecord() throws {
        let old = #"{"id":"do-x1y2","name":"DO","kind":"stdio","secretNames":[],"capabilities":[],"contract":1,"rev":1}"#
        let record = try ControlRecords.decoder.decode(ProviderRecord.self, from: Data(old.utf8))
        #expect(record.writtenBy == nil)
    }
}

@Suite("Write It for Me: Write the Map Again (#858 US4)")
struct ProviderDraftRewriteTests {
    @Test("Writing again starts from the kept record and its secrets; Save keeps the server")
    func rewrite() async throws {
        let harness = try await ProviderHarness()
        let world = DraftWorld(tools: ["droplet-list", "droplet-power-on", "droplet-power-off"])
        let draftHarness = DraftHarness(world: world)
        await harness.providers.draft(with: draftHarness.drafts)
        let add = DaemonAPI.ProviderAdd(name: "Droplets", kind: .stdio, command: "npx", args: ["-y", "@do/mcp"],
                                        map: DraftHarness.goodMap, secrets: ["TOKEN": "dop_v1_keptsecretvalue"])
        let kept = try await harness.call(DaemonAPI.Method.providersAdd, try JSONValue.encoding(add)).decode(DaemonAPI.ProviderSummary.self)

        // The sheet knows only the name and kind, and types no secret.
        let start = DaemonAPI.ProviderDraftStart(form: .init(name: "Droplets", kind: .stdio), provider: kept.id, runtimeID: "claude")
        let started = try await harness.call(DaemonAPI.Method.providersDraftStart, try JSONValue.encoding(start))
            .decode(DaemonAPI.ProviderDraftStarted.self)
        let prompt = try #require(world.started.first).prompt
        #expect(prompt.contains("It has this map now"))
        #expect(prompt.contains("droplet-power-on"))
        #expect(prompt.contains("TOKEN"))
        #expect(!prompt.contains("dop_v1_keptsecretvalue"))

        var object = try #require(DraftHarness.goodMap.objectValue)
        object["list"] = ["tool": "droplet-list", "items": "droplets", "id": "id", "name": "name", "state": "state"]
        let newMap = JSONValue.object(object)
        _ = try await draftHarness.tool(started.draft, AppTool.sendDraft, ["draft": newMap])
        let save = DaemonAPI.ProviderAdd(id: kept.id, name: "Droplets", kind: .stdio, map: newMap, draft: started.draft)
        _ = try await harness.call(DaemonAPI.Method.providersUpdate, try JSONValue.encoding(save))
        let object2 = try #require(try await harness.store.get(WorkspaceProviders.key(kept.id)))
        let record = try ControlRecords.decoder.decode(ProviderRecord.self, from: object2.data)
        #expect(record.command == "npx")
        #expect(record.args == ["-y", "@do/mcp"])
        #expect(record.map == newMap)
        #expect(record.writtenBy?.runtimeID == "claude")
        #expect(record.secretNames == ["TOKEN"])
    }

    @Test("A command provider's CLI is found from its commands")
    func cliOfCommands() {
        let record = ProviderRecord(id: .init(rawValue: "c"), name: "C", kind: .commands,
                                    commands: ["workspaces": [["name": "a", "start": "cws start a", "stop": "cws stop a"]]])
        #expect(WorkspaceProviders.cli(of: record) == "cws")
    }
}
