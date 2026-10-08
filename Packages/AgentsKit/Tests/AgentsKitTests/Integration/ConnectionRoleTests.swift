import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What each kind of connection may ask the daemon for.
///
/// The case this is for: an agent's own shell reaching the socket and answering its
/// own permission prompt, or starting an agent that never asks. The shell is a
/// stranger and learns only that the daemon is there; the helper its runtime started
/// reaches the agent tools and nothing a window does.
@Suite("What each connection may ask for", .timeLimit(.minutes(1)))
struct ConnectionRoleTests {
    private func path() -> String { "/tmp/ag-role-\(UUID().uuidString.prefix(8)).sock" }

    /// `waiting` bounds each raw read below; a transport handed the socket must not have
    /// it, or a slow answer reads as the socket closing.
    private func connect(_ path: String, waiting: Bool = true) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        precondition(result == 0, "could not connect: \(errno)")
        guard waiting else { return fd }
        var wait = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// How long to wait for a line that is owed. Generous, because a loaded machine can
    /// take many seconds to answer and no answer reads as "not refused"; it is only
    /// waited out by a test that is failing, since a read returns with its line.
    private static let answerWait: TimeInterval = 30

    /// One request, and the one line that answers it.
    private func ask(_ fd: Int32, _ method: String, _ params: String = "{}") async -> [String: Any]? {
        send(fd, method, params)
        return await readLine(fd, deadline: Date().addingTimeInterval(Self.answerWait))
    }

    private func send(_ fd: Int32, _ method: String, _ params: String = "{}") {
        let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":\(params)}\n"
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    /// Read off the pool: this blocks until the line or the deadline, and the daemon
    /// being asked needs the pool to answer.
    private func readLine(_ fd: Int32, deadline: Date) async -> [String: Any]? {
        guard let line = await offThePool({ Self.rawLine(fd, deadline: deadline) }) else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func rawLine(_ fd: Int32, deadline: Date) -> Data? {
        var received = Data()
        var byte: UInt8 = 0
        while Date() < deadline {
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 {
                if byte == UInt8(ascii: "\n") { return received }
                received.append(byte)
            } else if n == 0 {
                return nil
            }
        }
        return nil
    }

    private func errorCode(_ reply: [String: Any]?) -> Int? {
        (reply?["error"] as? [String: Any])?["code"] as? Int
    }

    /// A server whose every caller is `role`, and which says which methods reached it.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []
        func add(_ method: String) { lock.withLock { methods.append(method) } }
        var all: [String] { lock.withLock { methods } }
    }

    private func server(_ role: ConnectionRole, at path: String, heard: Heard) throws -> DaemonServer {
        let server = DaemonServer(url: URL(fileURLWithPath: path),
                                  roles: RolePolicy(summary: "test") { _ in role }) { _, method, _ in
            heard.add(method)
            return .success([:])
        }
        try server.start()
        return server
    }

    @Test func aStrangerLearnsOnlyThatTheDaemonIsThere() async throws {
        let path = path()
        let heard = Heard()
        let server = try server(.stranger, at: path, heard: heard)
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        #expect(errorCode(await ask(fd, DaemonAPI.Method.ping)) == nil)
        for method in [DaemonAPI.Method.permissionsAnswer, DaemonAPI.Method.agentsStart,
                       DaemonAPI.Method.agentsList, DaemonAPI.Method.shellInput,
                       DaemonAPI.Method.agentsFinishTurn, DaemonAPI.Method.daemonQuit] {
            #expect(errorCode(await ask(fd, method)) == DaemonAPI.Failure.notPermitted, "\(method)")
        }
        #expect(heard.all == [DaemonAPI.Method.ping], "nothing refused reached the daemon")
    }

    /// Agents Host's window counts projects and working agents, and does nothing else
    /// over the socket (#168): before, it was a stranger, refused, and redialled every 5 s.
    @Test func agentsHostReadsWhatItCountsAndNothingMore() async throws {
        let path = path()
        let heard = Heard()
        let server = try server(.hostApp, at: path, heard: heard)
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        for method in [DaemonAPI.Method.ping, DaemonAPI.Method.projectsList, DaemonAPI.Method.agentsList] {
            #expect(errorCode(await ask(fd, method)) == nil, "\(method)")
        }
        for method in [DaemonAPI.Method.permissionsAnswer, DaemonAPI.Method.agentsStart, DaemonAPI.Method.shellInput,
                       DaemonAPI.Method.agentsFinishTurn, DaemonAPI.Method.daemonQuit, DaemonAPI.Method.filesBrowse,
                       DaemonAPI.Method.connectionBindDevice] {
            #expect(errorCode(await ask(fd, method)) == DaemonAPI.Failure.notPermitted, "\(method)")
        }
        #expect(heard.all == [DaemonAPI.Method.ping, DaemonAPI.Method.projectsList, DaemonAPI.Method.agentsList])
        #expect(!ConnectionRole.hostApp.hearsNotifications && !ConnectionRole.hostApp.isPerson)
    }

    /// Who is what by signature: exact identifiers of this team, and anything else a
    /// stranger, a look-alike name included.
    @Test func agentsHostIsRecognisedByItsOwnIdentifierOnly() {
        #expect(RolePolicy.role(forSignedIdentifier: "com.alexecollins.agents.host") == .hostApp)
        #expect(RolePolicy.role(forSignedIdentifier: "com.alexecollins.agents") == .control)
        #expect(RolePolicy.role(forSignedIdentifier: "com.alexecollins.agents.bridge") == .control)
        #expect(RolePolicy.role(forSignedIdentifier: "agentsd") == .agent)
        for other in ["com.alexecollins.agents.hostile", "com.alexecollins.agents.host.helper",
                      "com.alexecollins.agents.remote", "com.apple.Terminal", "", nil] as [String?] {
            #expect(RolePolicy.role(forSignedIdentifier: other) == .stranger, "\(other ?? "nil")")
        }
        let host = CallerSignature.requirementText(team: "6T4RVD5724", identifiers: [RolePolicy.hostAppIdentifier])
        #expect(host == "anchor apple generic and certificate leaf[subject.OU] = \"6T4RVD5724\" "
                + "and (identifier \"com.alexecollins.agents.host\")")
    }

    @Test func aHelperReachesTheAgentToolsAndNothingAWindowDoes() async throws {
        let path = path()
        let heard = Heard()
        let server = try server(.agent, at: path, heard: heard)
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        for method in [DaemonAPI.Method.agentsFinishTurn, DaemonAPI.Method.agentsStartHelper,
                       DaemonAPI.Method.agentsStopHelper, DaemonAPI.Method.agentsParkHelper,
                       DaemonAPI.Method.agentsArchiveHelper, DaemonAPI.Method.agentsListHelpers,
                       DaemonAPI.Method.leasesLease, DaemonAPI.Method.eventsWait] {
            #expect(errorCode(await ask(fd, method)) == nil, "\(method)")
        }
        for method in [DaemonAPI.Method.permissionsAnswer, DaemonAPI.Method.agentsStart,
                       DaemonAPI.Method.agentsSetOption, DaemonAPI.Method.workflowsRun,
                       DaemonAPI.Method.shellInput, DaemonAPI.Method.credentialsLend,
                       DaemonAPI.Method.projectsSetHelperLimits] {
            #expect(errorCode(await ask(fd, method)) == DaemonAPI.Failure.notPermitted, "\(method)")
        }
    }

    /// A ceiling something can raise for itself is not a ceiling (#64): an agent, and a
    /// workflow's agent with it, may not set its project's helper limits. Refused at the
    /// socket, so the daemon never hears the request. A person's connection reaches it:
    /// the Mac's window, and since #111 a phone or a browser too.
    @Test func onlyAPersonSetsTheHelperLimits() async throws {
        let request = #"{"folder":"file:///tmp/p","limits":{"running":10,"notArchived":20}}"#
        for role in [ConnectionRole.agent, .pairing, .stranger] {
            let path = path()
            let heard = Heard()
            let server = try server(role, at: path, heard: heard)
            defer { server.stop() }
            let fd = connect(path)
            defer { close(fd) }
            #expect(errorCode(await ask(fd, DaemonAPI.Method.projectsSetHelperLimits, request))
                    == DaemonAPI.Failure.notPermitted, "\(role)")
            #expect(!heard.all.contains(DaemonAPI.Method.projectsSetHelperLimits), "\(role)")
        }
        for role in [ConnectionRole.control, .device] {
            let path = path()
            let heard = Heard()
            let server = try server(role, at: path, heard: heard)
            defer { server.stop() }
            let fd = connect(path)
            defer { close(fd) }
            #expect(errorCode(await ask(fd, DaemonAPI.Method.projectsSetHelperLimits, request)) == nil, "\(role)")
            #expect(heard.all.contains(DaemonAPI.Method.projectsSetHelperLimits), "\(role)")
        }
    }

    /// Transcripts and terminal output go by as notifications; only a window hears them.
    @Test func onlyAWindowHearsWhatTheDaemonSays() async throws {
        let windowPath = path(), strangerPath = path()
        let heard = Heard()
        let window = try server(.control, at: windowPath, heard: heard)
        let stranger = try server(.stranger, at: strangerPath, heard: heard)
        defer { window.stop(); stranger.stop() }
        let windowFD = connect(windowPath), strangerFD = connect(strangerPath)
        defer { close(windowFD); close(strangerFD) }
        await eventually("both are connected") { window.connectionCount == 1 && stranger.connectionCount == 1 }

        window.broadcast("agent/entry", ["secret": "for the window"])
        stranger.broadcast("agent/entry", ["secret": "for the window"])

        #expect(await readLine(windowFD, deadline: Date().addingTimeInterval(Self.answerWait))?["method"] as? String == "agent/entry")
        #expect(await readLine(strangerFD, deadline: Date().addingTimeInterval(1)) == nil)
    }

    // MARK: Devices (security review, Phase 3)

    private func named(_ id: UUID) -> String {
        "{\"id\":\"\(id.uuidString)\",\"name\":\"Phone\",\"kind\":\"iPhone\",\"publicKey\":\"\"}"
    }

    /// A phone the bridge carries may do what the Mac's window may (#111), and is still
    /// that one phone: it can't be bound again, or speak as an agent's helper.
    @Test func aDeviceMayDoWhatAWindowMay() async throws {
        let path = path()
        let heard = Heard()
        let server = try server(.control, at: path, heard: heard)
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        #expect(errorCode(await ask(fd, DaemonAPI.Method.connectionBindDevice, "{\"id\":\"\(UUID().uuidString)\"}")) == nil)
        for method in [DaemonAPI.Method.agentsList, DaemonAPI.Method.agentsStart, DaemonAPI.Method.agentsPrompt,
                       DaemonAPI.Method.permissionsAnswer, DaemonAPI.Method.shellInput, DaemonAPI.Method.filesRead,
                       DaemonAPI.Method.workflowsRun, DaemonAPI.Method.ping,
                       // What only the window could ask before #111.
                       DaemonAPI.Method.credentialsLend, DaemonAPI.Method.credentialsOffer,
                       DaemonAPI.Method.runtimeAuthenticate, DaemonAPI.Method.runtimeLogOut,
                       DaemonAPI.Method.filesBrowse, DaemonAPI.Method.filesWrite, DaemonAPI.Method.daemonQuit,
                       DaemonAPI.Method.devicesForget, DaemonAPI.Method.devicesList, DaemonAPI.Method.relayRegister,
                       DaemonAPI.Method.workflowsApprove, DaemonAPI.Method.projectsAdd] {
            #expect(errorCode(await ask(fd, method)) == nil, "\(method)")
            #expect(heard.all.contains(method), "\(method)")
        }
        #expect(errorCode(await ask(fd, DaemonAPI.Method.connectionBindDevice, "{\"id\":\"\(UUID().uuidString)\"}"))
                == DaemonAPI.Failure.notPermitted, "bound once, for good")
        #expect(!heard.all.contains(DaemonAPI.Method.connectionBindDevice), "the binding is the server's alone")
    }

    /// After a move (058, T085): a device that connects the old way is told where the
    /// control plane is now; a device still pairing is not.
    @Test(.flakyUnderLoad) func aMovedDeviceIsToldWhereTheControlPlaneIs() async throws {
        let folder = "/tmp/ag-mv-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let moved = DaemonAPI.ControlMoved(url: "https://mini.local:8791", pin: "pin", controlKey: Data([4, 1]), name: "mini")
        try JSONEncoder().encode(moved).write(to: URL(fileURLWithPath: folder + "/control-moved.json"))
        let path = folder + "/daemon.sock"
        let server = try server(.control, at: path, heard: Heard())
        defer { server.stop() }

        let pairing = connect(path)
        defer { close(pairing) }
        #expect(errorCode(await ask(pairing, DaemonAPI.Method.connectionBindDevice, "{\"pairing\":true}")) == nil)
        #expect(await readLine(pairing, deadline: Date().addingTimeInterval(1.5)) == nil)

        let fd = connect(path)
        defer { close(fd) }
        // The answer and the news, in whichever order they come: the news is sent half a
        // second after the binding, and on a loaded machine the answer can be later still.
        send(fd, DaemonAPI.Method.connectionBindDevice, "{\"id\":\"\(UUID().uuidString)\"}")
        var answer: [String: Any]?, told: [String: Any]?
        let deadline = Date().addingTimeInterval(Self.answerWait)
        while answer == nil || told == nil, let line = await readLine(fd, deadline: deadline) {
            if line["id"] != nil { answer = line } else { told = line }
        }
        #expect(answer != nil && errorCode(answer) == nil)
        #expect(told?["method"] as? String == DaemonAPI.Notification.controlMoved)
        let params = try JSONSerialization.data(withJSONObject: told?["params"] ?? [:])
        #expect(try JSONDecoder().decode(DaemonAPI.ControlMoved.self, from: params) == moved)
    }

    @Test func aDeviceBoundByTheBridgeCannotSpeakAsAnother() async throws {
        let path = path()
        let server = try server(.control, at: path, heard: Heard())
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }
        let mine = UUID(), theirs = UUID()

        #expect(errorCode(await ask(fd, DaemonAPI.Method.connectionBindDevice, "{\"id\":\"\(mine.uuidString)\"}")) == nil)
        #expect(errorCode(await ask(fd, DaemonAPI.Method.surfaceIdentify, named(theirs))) == DaemonAPI.Failure.notPermitted)
        #expect(errorCode(await ask(fd, DaemonAPI.Method.devicesAnnounce, named(theirs))) == DaemonAPI.Failure.notPermitted)
        #expect(errorCode(await ask(fd, DaemonAPI.Method.surfaceIdentify, named(mine))) == nil)
        #expect(errorCode(await ask(fd, DaemonAPI.Method.devicesAnnounce, named(mine))) == nil)
    }

    /// The LAN link, until it has keys to know a device by: the first name it gives
    /// is the only one it gets.
    @Test func anUnnamedDeviceIsWhoItFirstSaysItIs() async throws {
        let path = path()
        let server = try server(.control, at: path, heard: Heard())
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }
        let first = UUID()

        #expect(errorCode(await ask(fd, DaemonAPI.Method.connectionBindDevice)) == nil)
        #expect(errorCode(await ask(fd, DaemonAPI.Method.devicesAnnounce, named(first))) == nil)
        #expect(errorCode(await ask(fd, DaemonAPI.Method.surfaceIdentify, named(UUID()))) == DaemonAPI.Failure.notPermitted)
        #expect(errorCode(await ask(fd, DaemonAPI.Method.surfaceIdentify, named(first))) == nil)
    }

    /// A helper or a shell that could say this would be choosing its own rights.
    @Test func onlyAWindowsConnectionCanBeGivenToADevice() async throws {
        for role in [ConnectionRole.agent, .stranger] {
            let path = path()
            let server = try server(role, at: path, heard: Heard())
            defer { server.stop() }
            let fd = connect(path)
            defer { close(fd) }
            #expect(errorCode(await ask(fd, DaemonAPI.Method.connectionBindDevice)) == DaemonAPI.Failure.notPermitted)
        }
    }

    /// What the bridge and the relay host do with every connection they open: the
    /// answer is theirs and never reaches the device, and the connection is the device's
    /// from then on, with a window's rights (#111).
    @Test func theBinderWaitsForTheDaemonAndKeepsTheAnswerFromTheDevice() async throws {
        let path = path()
        let heard = Heard()
        let server = try server(.control, at: path, heard: heard)
        defer { server.stop() }

        let bound = try await DeviceBinder.bind(FDTransport(socket: connect(path, waiting: false)), device: UUID())
        defer { bound.close() }
        let client = JSONRPCConnection(transport: bound)
        await client.start()
        await #expect(throws: JSONRPCError.self) {
            _ = try await client.call(DaemonAPI.Method.connectionBindDevice)
        }
        _ = try await client.call(DaemonAPI.Method.daemonQuit)
        _ = try await client.call(DaemonAPI.Method.agentsList)
        #expect(heard.all == [DaemonAPI.Method.daemonQuit, DaemonAPI.Method.agentsList])
    }

    @Test func theBinderSaysSoWhenTheConnectionWasNotAWindows() async throws {
        let path = path()
        let server = try server(.agent, at: path, heard: Heard())
        defer { server.stop() }
        await #expect(throws: DeviceBinder.Failure.self) {
            _ = try await DeviceBinder.bind(FDTransport(socket: connect(path, waiting: false)), device: nil)
        }
    }

    // MARK: Signatures

    /// This test binary is not the app, the bridge or the helper, so under the real
    /// requirements it is what an agent's shell is.
    @Test func anUnsignedCallerIsAStrangerByItsSignature() throws {
        var pair: [Int32] = [0, 0]  // index-ok: two descriptors, filled by socketpair
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }

        #expect(CallerSignature.code(of: pair[0]) != nil, "the kernel names the caller")
        #expect(RolePolicy.signatures(team: "6T4RVD5724").role(pair[0]) == .stranger)
    }

    @Test func theRequirementsCompile() {
        #expect(CallerSignature.requirement(team: "6T4RVD5724", identifiers: RolePolicy.controlIdentifiers) != nil)
        #expect(CallerSignature.requirement(team: "6T4RVD5724", identifiers: [RolePolicy.helperIdentifier]) != nil)
        #expect(CallerSignature.requirement(team: "6T4RVD5724", identifiers: [RolePolicy.hostAppIdentifier]) != nil)
        #expect(RolePolicy.signedRoles.map(\.role) == [.control, .agent, .hostApp])
    }

    /// Nothing to tell programs apart by: open, and said so.
    @Test func aDaemonNotSignedByATeamIsOpenAndSaysSo() throws {
        let locations = StoreLocations(root: URL(fileURLWithPath: "/tmp/ag-role-root"))
        let policy = RolePolicy.forDaemon(at: locations, environment: ["AGENTS_ENFORCE_ROLES": "1"])
        #expect(CallerSignature.ownTeam == nil)
        #expect(policy.summary.hasPrefix("not signed by a team"))
    }

    /// Every method the app's tools relay is one an agent's call may make. A tool relayed
    /// and not allowed is a tool the agent is offered and always refused — `park_agent`
    /// was, with "agents/parkHelper is not open to this connection" (#64). Read from the
    /// sources, so a tool added to the relay without opening its method fails here.
    @Test func everyMethodTheHelperRelaysIsOpenToIt() throws {
        let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = try String(contentsOf: package.appending(path: "Sources/AgentsKit/ACP/Serve/AppService+Relay.swift"),
                                encoding: .utf8)
        let roles = try String(contentsOf: package.appending(path: "Sources/AgentsKitCore/Daemon/ConnectionRole.swift"),
                               encoding: .utf8)
        let allowed = roles.components(separatedBy: "public static let pairingMethods")[0]
        let relayed = helper.matches(of: /send\(DaemonAPI\.Method\.(\w+)/).map { String($0.output.1) }
        #expect(relayed.count >= 16)
        for name in Set(relayed) {
            #expect(allowed.contains("DaemonAPI.Method.\(name),"), "\(name) is relayed but not open to an agent")
        }
    }

    @Test func aHelperMayCallEveryToolItRelaysAndOnlyThose() {
        // 27 tools (three more since #481), a tool with a view (#187), and the two a
        // stranger has.
        #expect(ConnectionRole.agentMethods.count == 30)
        #expect(ConnectionRole.agent.allows(DaemonAPI.Method.agentsAskForm))
        #expect(ConnectionRole.stranger.allows(DaemonAPI.Method.daemonStatus))
        #expect(!ConnectionRole.agent.allows(DaemonAPI.Method.filesBrowse))
        #expect(ConnectionRole.control.allows("anything/atAll"))
        #expect(!ConnectionRole.agent.hearsNotifications && !ConnectionRole.stranger.hearsNotifications)
        #expect(ConnectionRole.device.hearsNotifications, "the phone's lists are kept by them")
    }
    /// An agent moves only itself, by its token; a window or the phone moves an agent by
    /// its id; a stranger moves nothing (053).
    @Test func movingIsTheCallersOwnAndNeverAStrangers() {
        #expect(ConnectionRole.agent.allows(DaemonAPI.Method.agentsMoveSelf))
        #expect(!ConnectionRole.agent.allows(DaemonAPI.Method.agentsMove))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.agentsMove))
        #expect(!ConnectionRole.stranger.allows(DaemonAPI.Method.agentsMove))
        #expect(!ConnectionRole.stranger.allows(DaemonAPI.Method.agentsMoveSelf))
    }
}
