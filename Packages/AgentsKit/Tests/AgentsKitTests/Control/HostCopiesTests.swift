import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What each host last listed (#962): kept from its own replies as they pass, and given to a
/// client that starts while it is offline.
@Suite("What an offline host last listed")
struct HostCopiesTests {
    let host = MachineRef(rawValue: "k3v9x0qa")

    static func reply(_ result: JSONValue) throws -> String {
        try JSONRPCCodec.encode(.success(id: .number(1), result: result))
    }

    @Test func onlyWholeListsAreKept() {
        #expect(HostCopies.keeps(DaemonAPI.Method.foldersList, ["includeArchived": true]))
        #expect(HostCopies.keeps(DaemonAPI.Method.agentsList, ["includeArchived": false, "lean": true, "limit": 500]))
        #expect(HostCopies.keeps(DaemonAPI.Method.agentsList,
                                 ["includeArchived": false, "archivedCommands": false, "archivedOnly": false, "lean": true]))
        // A narrower list, a later page, archived ones or the whole agents are not.
        #expect(!HostCopies.keeps(DaemonAPI.Method.agentsList, ["lean": true, "folder": "/src/api"]))
        #expect(!HostCopies.keeps(DaemonAPI.Method.agentsList, ["lean": true, "after": ["id": "a"]]))
        #expect(!HostCopies.keeps(DaemonAPI.Method.agentsList, ["lean": true, "includeArchived": true]))
        #expect(!HostCopies.keeps(DaemonAPI.Method.agentsList, ["includeArchived": false]))
        #expect(!HostCopies.keeps(DaemonAPI.Method.agentsList, nil))
        #expect(!HostCopies.keeps("files/list", nil))
    }

    @Test func whatWasListedIsGivenBackAfterARestartAndGoesWithTheHost() async throws {
        let store = MemoryStore()
        let copies = HostCopies(store: store)
        #expect(await copies.lastHeard(host) == ["host": "k3v9x0qa"])
        let folders: JSONValue = [["folder": ["folder": "/src/api"]]]
        await copies.take(host, method: DaemonAPI.Method.foldersList, reply: try Self.reply(folders))
        await copies.take(host, method: DaemonAPI.Method.agentsList, reply: try Self.reply([["id": "a1", "title": "Fix login"]]))
        // A refusal changes nothing.
        await copies.take(host, method: DaemonAPI.Method.agentsList,
                          reply: try JSONRPCCodec.encode(.failure(id: .number(2), error: JSONRPCError(code: 1, message: "no"))))

        let again = HostCopies(store: store)
        let heard = try #require(await again.lastHeard(host).objectValue)
        #expect(heard["folders"] == folders)
        #expect(heard["agents"] == [["id": "a1", "title": "Fix login"]])
        #expect(heard["heardAt"] != nil)

        await again.forget(host)
        #expect(await HostCopies(store: store).lastHeard(host) == ["host": "k3v9x0qa"])
    }

    @Test func atMostAPageOfSessionsIsKept() async throws {
        let copies = HostCopies(store: MemoryStore())
        let many = JSONValue.array((0..<(HostCopies.agentsKept + 20)).map { ["id": .string("a\($0)")] })
        await copies.take(host, method: DaemonAPI.Method.agentsList, reply: try Self.reply(many))
        guard case .array(let kept)? = await copies.lastHeard(host).objectValue?["agents"] else {
            Issue.record("no agents kept")
            return
        }
        #expect(kept.count == HostCopies.agentsKept)
    }

    @Test func theRouterHandsOnAHostsAnswerToAWholeListOnly() async throws {
        let router = ControlRouter(handler: StubControl(), knownHosts: [host])
        let heard = CopiedLines()
        await router.setCopier { host, method, _ in heard.add("\(host.rawValue) \(method)") }
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(host, transport: ours)
        let uplink = FakeUplinkHost(transport: theirs)
        let (mine, window) = PairedTransport.pair()
        await router.attachClient(client(.mac), transport: mine)
        let sender = FakeControlClient(transport: window)
        await eventually { uplink.openChannels.count == 1 }

        for (id, params) in [(1, ["lean": true] as JSONValue), (2, ["lean": true, "folder": "/src"] as JSONValue)] {
            let message = try JSONRPCCodec.encode(.request(id: .number(id), method: DaemonAPI.Method.agentsList, params: params))
            try sender.send(ControlWire.wrap(host: host, message: message))
        }
        await eventually { sender.lines.count == 2 }
        #expect(heard.all == ["k3v9x0qa agents/list"])
        uplink.stop()
    }
}

private final class CopiedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [String] = []
    func add(_ line: String) { lock.withLock { said.append(line) } }
    var all: [String] { lock.withLock { said } }
}
