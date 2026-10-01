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

    // MARK: The control plane

    /// The phone's home connection is the bare wire. When the host behind it goes, a call
    /// already on its way should be answered with a failure, as one the uplink refuses is
    /// (`aRequestTheUplinkWillNotTakeIsRefusedNotLost`). Today it is dropped, and the
    /// phone waits on it: the Remote's reconnect hang after a Mac restart (073, D2).
    @Test func aCallInFlightWhenTheHostGoesIsAnswered() async throws {
        let home = HostID(rawValue: "mac")
        let router = ControlRouter(handler: StubControl(), homeHost: home)
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(home, transport: ours)
        let (phoneOurs, phoneTheirs) = PairedTransport.pair()
        await router.attachClient(client(.device), transport: phoneOurs)
        let phone = FakeControlClient(transport: phoneTheirs)
        _ = await eventually { await router.channels(of: home).count == 1 }

        // Sent, and never answered: the host is going.
        try phone.send(#"{"jsonrpc":"2.0","id":3,"method":"agents/list"}"#)
        try await Task.sleep(for: .milliseconds(100))
        theirs.close()

        await withKnownIssue("the router drops a call in flight when its host goes (073)") {
            let answered = await eventually("an answer to the call in flight", within: .seconds(2)) {
                phone.lines.contains { $0.contains(#""id":3"#) }
            }
            #expect(answered)
        }
        phoneTheirs.close()
    }
}
