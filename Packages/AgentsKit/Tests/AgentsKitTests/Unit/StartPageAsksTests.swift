import Foundation
import Testing
@testable import AgentsKitCore

/// The phone's New session after reconnects (#1096): a call the page waits on ends when
/// the link drops or its reply is lost, and each ask with no answer is asked again once
/// the host answers, so the page gets to its choices and its personas.
@Suite("The New session page's asks", .timeLimit(.minutes(1)))
struct StartPageAsksTests {
    /// A host that answers pings always, and the page's calls as each connection's way says:
    /// the link drops under the first one, the replies are lost, or it answers.
    final class Host: DaemonLink, @unchecked Sendable {
        enum Way: Sendable { case dropsLink, losesReplies, answers }
        private let lock = NSLock()
        private var ways: [Way]
        private var _asked: [String] = []
        var asked: [String] { lock.withLock { _asked } }

        init(_ ways: [Way]) { self.ways = ways }

        private func nextWay() -> Way {
            lock.withLock { ways.count > 1 ? ways.removeFirst() : ways[0] }
        }

        private func heard(_ method: String) {
            lock.withLock { _asked.append(method) }
        }

        func transport() async throws -> any LineTransport {
            let way = nextWay()
            let (near, far) = PairedTransport.pair()
            _ = Task { [weak self] in
                // The link drops once the page's three calls are all in, so each is heard
                // whatever order they arrive in (#1320).
                var calls = 0
                for try await line in far.lines() {
                    guard let self,
                          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = object["id"] as? Int, let method = object["method"] as? String else { continue }
                    if method == DaemonAPI.Method.ping {
                        try? far.write(line: #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
                        continue
                    }
                    self.heard(method)
                    calls += 1
                    switch way {
                    case .dropsLink: if calls == StartPageAsks.Ask.allCases.count { far.close() }
                    case .losesReplies: continue
                    case .answers: try? far.write(line: Self.reply(id, to: method))
                    }
                }
            }
            return near
        }

        func start() async throws {}

        static let persona = Persona(id: "reviewer", name: "Reviewer", origin: .folder)

        private static func reply(_ id: Int, to method: String) -> String {
            let result: JSONValue? = switch method {
            case DaemonAPI.Method.agentsOptions:
                try? JSONValue.encoding(DaemonAPI.OptionsResponse(draftID: UUID(), options: []))
            case DaemonAPI.Method.personasList: try? JSONValue.encoding([persona])
            default: try? JSONValue.encoding(DaemonAPI.WorktreesListResponse.notARepository)
            }
            let encoded = (try? JSONEncoder().encode(result ?? .null)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
            return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(encoded)}"#
        }
    }

    private let folder = URL(filePath: "/tmp/folder")

    /// What the page asks, as the Remote's model asks it: each ask with no answer, side by
    /// side, each with its own deadline. What came back, by ask.
    private func askAgain(_ asks: inout StartPageAsks, on client: DaemonClient,
                          patience: Duration? = nil) async -> (personas: [Persona]?, began: ContinuousClock.Instant) {
        let began = ContinuousClock.now
        let wanted = asks.toAskAgain
        for ask in wanted { asks.asking(ask) }
        func within(_ method: String) -> Duration { patience ?? StartPageAsks.patience(for: method) }
        let folder = folder
        async let choices: Bool = wanted.contains(.choices) ? ((try? await client.callWithin(
            within(DaemonAPI.Method.agentsOptions), DaemonAPI.Method.agentsOptions,
            DaemonAPI.OptionsRequest(runtimeID: "claude", cwd: folder),
            returning: DaemonAPI.OptionsResponse.self)) != nil) : false
        async let personas: [Persona]? = wanted.contains(.personas) ? (try? await client.callWithin(
            within(DaemonAPI.Method.personasList), DaemonAPI.Method.personasList,
            DaemonAPI.PersonasListRequest(folder: folder), returning: [Persona].self)) : nil
        async let worktrees: Bool = wanted.contains(.worktrees) ? ((try? await client.callWithin(
            within(DaemonAPI.Method.worktreesList), DaemonAPI.Method.worktreesList,
            DaemonAPI.WorktreesListRequest(folder: folder),
            returning: DaemonAPI.WorktreesListResponse.self)) != nil) : false
        let (gotChoices, gotPersonas, gotWorktrees) = await (choices, personas, worktrees)
        if gotChoices { asks.answered(.choices) }
        if gotPersonas != nil { asks.answered(.personas) }
        if gotWorktrees { asks.answered(.worktrees) }
        return (gotPersonas, began)
    }

    /// The issue's case: the link drops under the page's calls, twice, and comes back each
    /// time. Each drop fails the calls at once, not after their deadline, and the third
    /// connection answers every ask: the page has its choices and its Persona row.
    @Test func aPageWhoseLinkDropsTwiceGetsItsChoicesAndPersonas() async throws {
        let host = Host([.dropsLink, .dropsLink, .answers])
        let client = DaemonClient(link: host)
        var asks = StartPageAsks()
        asks.opened()

        for _ in 0..<2 {
            try await client.connect(startIfNeeded: false)
            let (personas, began) = await askAgain(&asks, on: client)
            #expect(personas == nil)
            // The drop ended them: none waited for its 30 seconds, let alone 2 minutes.
            #expect(ContinuousClock.now - began < .seconds(10))
            #expect(asks.toAskAgain == Set(StartPageAsks.Ask.allCases))
        }

        try await client.connect(startIfNeeded: false)
        let (personas, _) = await askAgain(&asks, on: client)
        #expect(personas == [Host.persona])
        #expect(asks.toAskAgain.isEmpty)
        #expect(host.asked.filter { $0 == DaemonAPI.Method.agentsOptions }.count == 3)
        #expect(host.asked.filter { $0 == DaemonAPI.Method.personasList }.count == 3)
    }

    /// A reply lost while the link stays up ends at the deadline, not never; the host still
    /// answers pings, so the connection is kept, and the next connection's answers count.
    @Test func aReplyLostOnALiveLinkEndsAtItsDeadline() async throws {
        let host = Host([.losesReplies, .answers])
        let client = DaemonClient(link: host)
        var asks = StartPageAsks()

        try await client.connect(startIfNeeded: false)
        await #expect(throws: DaemonClient.NoAnswer.self) {
            try await client.callWithin(.milliseconds(300), DaemonAPI.Method.agentsOptions,
                                        DaemonAPI.OptionsRequest(runtimeID: "claude", cwd: folder),
                                        returning: DaemonAPI.OptionsResponse.self)
        }
        #expect(await client.isConnected)
        _ = await askAgain(&asks, on: client, patience: .milliseconds(300))
        #expect(asks.toAskAgain == Set(StartPageAsks.Ask.allCases))

        // A reconnect: what had no answer is asked again, and answered.
        await client.disconnect()
        try await client.connect(startIfNeeded: false)
        let (personas, _) = await askAgain(&asks, on: client)
        #expect(personas == [Host.persona])
        #expect(asks.toAskAgain.isEmpty)
    }

    @Test func openingAgainForgetsWhatWasAnswered() {
        var asks = StartPageAsks()
        for ask in StartPageAsks.Ask.allCases { asks.answered(ask) }
        #expect(asks.toAskAgain.isEmpty)
        asks.asking(.personas)
        #expect(asks.toAskAgain == [.personas])
        asks.opened()
        #expect(asks.toAskAgain == Set(StartPageAsks.Ask.allCases))
    }

    @Test func aDraftIsGivenLongerThanAList() {
        #expect(StartPageAsks.patience(for: DaemonAPI.Method.agentsOptions) == .seconds(120))
        #expect(StartPageAsks.patience(for: DaemonAPI.Method.personasList) == .seconds(30))
    }
}
