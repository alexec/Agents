import Foundation
import Testing
@testable import AgentsKitCore

/// Replies dropped and delayed on the way back (073): what waits on them ends, and says
/// so, rather than leaving an app that looks connected and does nothing.
@Suite("Dropped and delayed replies", .timeLimit(.minutes(1)))
struct DroppedReplyTests {
    /// A host that answers pings, and every other call as `fault` says.
    final class Host: DaemonLink, @unchecked Sendable {
        enum Fault: Sendable { case none, drop, delay(Duration), quiet }
        private let lock = NSLock()
        private var _fault: Fault
        var fault: Fault {
            get { lock.withLock { _fault } }
            set { lock.withLock { _fault = newValue } }
        }

        init(_ fault: Fault) { _fault = fault }

        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            _ = Task { [weak self] in
                for try await line in far.lines() {
                    guard let self,
                          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = object["id"] as? Int else { continue }
                    let reply = #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#
                    let isPing = object["method"] as? String == DaemonAPI.Method.ping
                    switch self.fault {
                    case .quiet: continue
                    case _ where isPing, .none: try? far.write(line: reply)
                    case .drop: continue
                    case .delay(let by):
                        Task {
                            try? await Task.sleep(for: by)
                            try? far.write(line: reply)
                        }
                    }
                }
            }
            return near
        }

        func start() async throws {}
    }

    private func connected(_ fault: Host.Fault) async throws -> (DaemonClient, Host) {
        let host = Host(.none)
        let client = DaemonClient(link: host)
        try await client.connect(startIfNeeded: false)
        host.fault = fault
        return (client, host)
    }

    @Test func aDroppedReplyEndsInNoAnswerAndTheConnectionStays() async throws {
        let (client, _) = try await connected(.drop)
        let started = ContinuousClock.now
        await #expect(throws: DaemonClient.NoAnswer.self) {
            try await DaemonClient.$patience.withValue(.milliseconds(300)) {
                try await client.call(DaemonAPI.Method.agentsList)
            }
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        // It still answers pings: only that call was lost, so the connection is kept.
        #expect(await client.isConnected)
    }

    @Test func aHostGoneQuietIsLetGoSoTheListenerReconnects() async throws {
        let (client, _) = try await connected(.quiet)
        // Its ping unanswered too, the connection is closed, which fails the call with it.
        await #expect(throws: (any Error).self) {
            try await DaemonClient.$patience.withValue(.milliseconds(300)) {
                try await client.call(DaemonAPI.Method.agentsList)
            }
        }
        #expect(await !client.isConnected)
    }

    @Test func aReplyLateButInsideThePatienceArrives() async throws {
        let (client, _) = try await connected(.delay(.milliseconds(100)))
        let answer = try await DaemonClient.$patience.withValue(.seconds(5)) {
            try await client.call(DaemonAPI.Method.agentsList)
        }
        #expect(answer == [:])
    }

    @Test func aReplyTooLateIsNoAnswerAndTheNextCallStillWorks() async throws {
        let (client, host) = try await connected(.delay(.seconds(2)))
        await #expect(throws: DaemonClient.NoAnswer.self) {
            try await DaemonClient.$patience.withValue(.milliseconds(200)) {
                try await client.call(DaemonAPI.Method.agentsList)
            }
        }
        host.fault = .none
        let answer = try await DaemonClient.$patience.withValue(.seconds(5)) {
            try await client.call(DaemonAPI.Method.agentsList)
        }
        #expect(answer == [:])
    }

    /// A catching-up refresh makes its calls side by side; each is given the patience.
    @Test func thePatienceReachesCallsMadeSideBySide() async throws {
        let (client, _) = try await connected(.drop)
        let failed = await DaemonClient.$patience.withValue(.milliseconds(300)) {
            func noAnswer(_ method: String) async -> Bool {
                do { try await client.call(method); return false } catch { return error is DaemonClient.NoAnswer }
            }
            async let a = noAnswer(DaemonAPI.Method.agentsList)
            async let b = noAnswer(DaemonAPI.Method.projectsList)
            return await [a, b].filter { $0 }
        }
        #expect(failed.count == 2)
    }

    /// Outside the patience nothing changes: a call waits as long as its answer takes.
    @Test func withoutAPatienceACallStillWaits() async throws {
        let (client, _) = try await connected(.delay(.milliseconds(600)))
        let answer = try await client.call(DaemonAPI.Method.agentsList)
        #expect(answer == [:])
    }

    // MARK: A send held only while the host is there (#208)

    /// The Mac went quiet under a send: its pings go unanswered, the connection is let go,
    /// and the send fails rather than holding the Sending indicator up for good.
    @Test func aSendToAHostGoneQuietFails() async throws {
        let (client, _) = try await connected(.quiet)
        let started = ContinuousClock.now
        await #expect(throws: JSONRPCTransportError.self) {
            try await client.callWhileAnswering(DaemonAPI.Method.agentsPrompt, checkingEvery: .milliseconds(100),
                                                pingPatience: .milliseconds(200))
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await !client.isConnected)
    }

    /// A slow answer from a host that keeps answering pings is waited for: a start that
    /// makes a worktree is not a host gone away.
    @Test func aSlowAnswerFromAHostThatIsThereArrives() async throws {
        let (client, _) = try await connected(.delay(.milliseconds(800)))
        let answer = try await client.callWhileAnswering(DaemonAPI.Method.agentsStart,
                                                         checkingEvery: .milliseconds(100),
                                                         pingPatience: .seconds(2))
        #expect(answer == [:])
        #expect(await client.isConnected)
    }

    // MARK: The control plane

    private let home = HostID(rawValue: "mac")

    /// A home host that never answers, and a phone on the bare wire, as today's Remote is.
    private func silentHomeAndPhone(_ kind: ClientRecord.Kind = .iPhone)
        async -> (ControlRouter, PairedTransport, FakeControlClient, PairedTransport) {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(home, transport: ours)
        let (phoneOurs, phoneTheirs) = PairedTransport.pair()
        await router.attachClient(client(kind), transport: phoneOurs)
        _ = await eventually { await router.channels(of: home).count == 1 }
        return (router, theirs, FakeControlClient(transport: phoneTheirs), phoneTheirs)
    }

    /// The phone's home connection is the bare wire. When the host behind it goes, a call
    /// already on its way is answered with a failure, as one the uplink refuses is
    /// (`aRequestTheUplinkWillNotTakeIsRefusedNotLost`). It used to be dropped, and the
    /// phone waited on it: the Remote's reconnect hang after a Mac restart (#77).
    @Test func aCallInFlightWhenTheHostGoesIsAnswered() async throws {
        let (router, host, phone, phoneEnd) = await silentHomeAndPhone()
        try phone.send(#"{"jsonrpc":"2.0","id":3,"method":"agents/list"}"#)
        _ = await eventually { await router.inFlight(of: home) == 1 }
        host.close()

        #expect(await eventually("an answer to the call in flight", within: .seconds(5)) {
            phone.lines.contains { $0.contains(#""id":3"#) && $0.contains("\(DaemonAPI.Failure.hostOffline)") }
        })
        phoneEnd.close()
    }

    /// And the bare wire hears nothing else about hosts, so its session ends: the phone
    /// reconnects, says who it is again, and reads everything afresh from the daemon that
    /// came back, which knows nothing of it (#77).
    @Test func aBareClientOfTheHomeHostIsLetGoWhenItGoes() async throws {
        let (router, host, _, phoneEnd) = await silentHomeAndPhone()
        #expect(await router.sessionCount == 1)
        host.close()
        #expect(await eventually("the phone's session ended") { await router.sessionCount == 0 })
        phoneEnd.close()
    }

    /// A window speaks the wrapped wire and is told by `control/hostChanged`; its session
    /// stays, and its call in flight is answered too.
    @Test func aWrappedClientKeepsItsSessionAndHearsItsCallAnswered() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(home, transport: ours)
        let (windowOurs, windowTheirs) = PairedTransport.pair()
        await router.attachClient(client(.mac), transport: windowOurs)
        let window = FakeControlClient(transport: windowTheirs)
        _ = await eventually { await router.channels(of: home).count == 1 }
        try window.request(9, DaemonAPI.Method.agentsList, host: home)
        _ = await eventually { await router.inFlight(of: home) == 1 }
        theirs.close()
        #expect(await eventually("an answer to the call in flight") {
            window.lines.contains { $0.contains(#""id":9"#) && $0.contains("\(DaemonAPI.Failure.hostOffline)") }
        })
        #expect(await router.sessionCount == 1)
        windowTheirs.close()
    }

    /// A call the host did answer is not answered a second time when it goes.
    @Test func aCallAlreadyAnsweredIsNotAnsweredAgain() async throws {
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(home, transport: ours)
        let host = FakeUplinkHost(transport: theirs)
        let (phoneOurs, phoneTheirs) = PairedTransport.pair()
        await router.attachClient(client(.iPhone), transport: phoneOurs)
        let phone = FakeControlClient(transport: phoneTheirs)
        _ = await eventually { host.openChannels.count == 1 }
        try phone.send(#"{"jsonrpc":"2.0","id":5,"method":"agents/list"}"#)
        _ = await eventually { !phone.lines.isEmpty }
        #expect(await router.inFlight(of: home) == 0)
        host.stop()
        _ = await eventually { await router.sessionCount == 0 }
        #expect(phone.lines.filter { $0.contains(#""id":5"#) }.count == 1)
        phoneTheirs.close()
    }

    // MARK: Reading a reply's id without decoding it

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":7,"result":{"id":99,"method":"x"}}"#,
        #"{"result":[{"id":1}],"jsonrpc":"2.0","id":12}"#,
        #"{"error":{"code":-1,"message":"no \"id\": here"},"id":"abc","jsonrpc":"2.0"}"#,
        #"{ "id" : -4 , "result" : "}{[" }"#,
        #"{"jsonrpc":"2.0","method":"agent/changed","params":{"id":3}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"credentials/want","params":{}}"#,
        #"{"jsonrpc":"2.0","error":{"code":-32700,"message":"bad"},"id":null}"#,
        #"not json"#,
    ])
    func theScannedIDIsTheDecodedOne(_ line: String) {
        let decoded: JSONRPCID? = switch try? JSONRPCCodec.decode(line: line) {
        case .success(let id, _)?: id
        case .failure(let id?, _)?: id
        default: nil
        }
        #expect(ControlRouter.answeredID(line) == decoded)
    }
}
