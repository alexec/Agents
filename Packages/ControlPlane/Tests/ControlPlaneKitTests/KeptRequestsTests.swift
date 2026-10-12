import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

// Start a workspace by using it (#691 US3): a prompt or an agent start for a stopped host
// is kept, starts it, and goes once the host connects. Through the router, as a client's
// line and a host's uplink would go, with the stand-in provider.

/// A host's end of an uplink: answers each request, a start with a new agent's id, and
/// remembers every request it was sent.
final class KeptHost: @unchecked Sendable {
    let transport: PairedTransport
    private let lock = NSLock()
    private var heard: [(method: String, params: JSONValue?)] = []
    private(set) var made = UUID()
    /// Refuse prompts with this, as a host whose folder has gone would.
    var refuse: String?

    init(transport: PairedTransport) {
        self.transport = transport
        Task { [weak self] in
            do {
                for try await line in transport.lines() { self?.hear(line) }
            } catch {}
        }
    }

    private func hear(_ line: String) {
        guard case .message(let channel, let message)? = try? ControlWire.readHost(line),
              case .request(let id, let method, let params)? = try? JSONRPCCodec.decode(line: message) else { return }
        lock.withLock { heard.append((method, params)) }
        let reply: JSONRPCMessage
        if method == DaemonAPI.Method.agentsStart {
            reply = .success(id: id, result: .string(made.uuidString))
        } else if let refuse {
            reply = .failure(id: id, error: JSONRPCError(code: DaemonAPI.Failure.folderGone, message: refuse))
        } else {
            reply = .success(id: id, result: [:])
        }
        if let line = try? JSONRPCCodec.encode(reply) {
            try? transport.write(line: ControlWire.channel(channel, message: line))
        }
    }

    var requests: [(method: String, params: JSONValue?)] { lock.withLock { heard } }
}

/// A client's end: every line it hears.
final class KeptClient: @unchecked Sendable {
    let transport: PairedTransport
    private let lock = NSLock()
    private var heard: [String] = []

    init(transport: PairedTransport) {
        self.transport = transport
        Task { [weak self] in
            do {
                for try await line in transport.lines() { self?.lock.withLock { self?.heard.append(line) } }
            } catch {}
        }
    }

    func send(_ id: Int, _ method: String, _ params: JSONValue, to host: HostID) throws {
        let message = try JSONRPCCodec.encode(.request(id: .number(id), method: method, params: params))
        try transport.write(line: ControlWire.wrap(host: host, message: message))
    }

    /// The reply to request `id`, once it comes.
    func reply(_ id: Int) async throws -> JSONRPCMessage {
        for _ in 0..<500 {
            for line in lock.withLock({ heard }) {
                // The control plane's lines to a client are framed as a client's to it are.
                guard case .toHost(_, let message)? = try? ControlWire.readClient(line),
                      let decoded = try? JSONRPCCodec.decode(line: message) else { continue }
                switch decoded {
                case .success(.number(id), _), .failure(.number(id)?, _): return decoded
                default: continue
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProviderFailure("no reply to \(id)")
    }

    func heardNotification(_ method: String) -> Bool {
        lock.withLock { heard }.contains { $0.contains(method) }
    }
}

extension ProviderHarness {
    /// Kept requests, wired as `ControlService` wires them.
    func keeper(store: MemoryStore? = nil) async -> KeptRequests {
        let providers = self.providers
        let kept = KeptRequests(store: store ?? self.store, router: router,
                                hooks: .init(keepable: { await providers.keepable($0) },
                                             start: { await providers.startForUse($0, by: $1) }),
                                log: { _ in })
        await providers.keep(with: kept)
        await router.setKeeper(kept)
        return kept
    }

    func connectClient() async -> KeptClient {
        let (ours, theirs) = PairedTransport.pair()
        await router.attachClient(ClientRecord(id: UUID(), name: "phone", kind: .iPhone, publicKey: Data(), paired: Date()),
                                  transport: ours)
        return KeptClient(transport: theirs)
    }

    func connectHost() async -> KeptHost {
        let (ours, theirs) = PairedTransport.pair()
        await router.attachHost(devbox, transport: ours)
        return KeptHost(transport: theirs)
    }

    func prompt(_ text: String, agent: UUID = UUID()) throws -> JSONValue {
        try JSONValue.encoding(DaemonAPI.PromptRequest(agentID: agent, text: text))
    }
}

@Suite("Kept requests (#691 US3)")
struct KeptRequestsTests {
    @Test func aPromptForAStoppedHostIsKeptStartsItAndGoesOnceItConnects() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let kept = await h.keeper()
        let phone = await h.connectClient()

        try phone.send(1, DaemonAPI.Method.agentsPrompt, try h.prompt("run the migration again"), to: h.devbox)
        guard case .failure(_, let error) = try await phone.reply(1) else { Issue.record("not kept"); return }
        #expect(error.code == DaemonAPI.Failure.kept)
        #expect(error.message == "devbox is starting. This is sent when it connects.")
        #expect(try error.data?.decode(DaemonAPI.KeptRequest.self).text == "run the migration again")
        _ = try await h.waitFor("starting")
        #expect(await h.provider.starts == 1)
        #expect(await kept.all().count == 1)

        let host = await h.connectHost()
        for _ in 0..<300 where host.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(host.requests.map(\.method) == [DaemonAPI.Method.agentsPrompt])
        // An id the host dedupes by, as the phone sent none.
        #expect(host.requests.first?.params?.objectValue?["sendID"]?.stringValue != nil)
        for _ in 0..<300 where await !kept.all().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await kept.all().isEmpty)
        // Said after the record goes, so it can trail the empty list.
        for _ in 0..<300 where !phone.heardNotification(DaemonAPI.Notification.controlKeptDelivered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(phone.heardNotification(DaemonAPI.Notification.controlKeptDelivered))
    }

    @Test func aKeptStartSaysWhichAgentItMade() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        _ = await h.keeper()
        let phone = await h.connectClient()
        let start = DaemonAPI.StartRequest(runtimeID: "claude", cwd: URL(fileURLWithPath: "/home/alex/app"),
                                           prompt: "fix the login", draftID: UUID())
        try phone.send(1, DaemonAPI.Method.agentsStart, try JSONValue.encoding(start), to: h.devbox)
        guard case .failure(_, let error) = try await phone.reply(1),
              let summary = try error.data?.decode(DaemonAPI.KeptRequest.self) else { Issue.record("not kept"); return }
        #expect(summary.isStart)
        #expect(summary.folder?.path == "/home/alex/app")
        #expect(summary.runtimeID == "claude")

        let host = await h.connectHost()
        for _ in 0..<300 where !phone.heardNotification(DaemonAPI.Notification.controlKeptDelivered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(phone.heardNotification(host.made.uuidString))
        let sent = try #require(host.requests.first?.params?.objectValue)
        #expect(sent["requestID"]?.stringValue != nil)
        // The draft was a runtime on the host before it stopped; there is none now.
        #expect(sent["draftID"] == nil)
    }

    @Test func whatIsKeptOutlivesARestartOfTheControlPlane() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let kept = await h.keeper()
        _ = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("one"), from: h.caller)
        _ = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("two"), from: h.caller)

        let again = await h.keeper()
        #expect(await again.all().map(\.text) == ["one", "two"])
        let host = await h.connectHost()
        for _ in 0..<300 where host.requests.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        // In the order they came, once each.
        #expect(host.requests.compactMap { $0.params?.objectValue?["text"]?.stringValue } == ["one", "two"])
    }

    @Test func aDroppedPromptIsNotSentAndTheStartGoesOn() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let kept = await h.keeper()
        let error = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("never"),
                                    from: h.caller)
        let summary = try #require(try error?.data?.decode(DaemonAPI.KeptRequest.self))
        _ = try await h.call(DaemonAPI.Method.hostsDropKept,
                             try JSONValue.encoding(DaemonAPI.KeptRequestID(host: h.devbox, id: summary.id)))
        #expect(await kept.all().isEmpty)
        #expect(try await h.row().state == "starting")

        let host = await h.connectHost()
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.requests.isEmpty)
    }

    @Test func twentyArePlentyForOneHost() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let kept = await h.keeper()
        for n in 0..<KeptRequests.limit {
            let error = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("\(n)"),
                                        from: h.caller)
            #expect(error?.code == DaemonAPI.Failure.kept)
        }
        let refused = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("more"),
                                      from: h.caller)
        #expect(refused?.code == DaemonAPI.Failure.hostOffline)
        #expect(refused?.message == "devbox is starting; too many prompts are waiting.")
    }

    @Test func aReadNeverStartsTheWorkspace() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        _ = await h.keeper()
        let phone = await h.connectClient()
        _ = try await h.waitFor("stopped")
        try phone.send(1, DaemonAPI.Method.agentsTranscript, ["agentID": .string(UUID().uuidString)], to: h.devbox)
        guard case .failure(_, let error) = try await phone.reply(1) else { Issue.record("answered"); return }
        #expect(error.code == DaemonAPI.Failure.hostOffline)
        // Says it is stopped, and can be started (FR-022).
        #expect(error.message == "That host is stopped. Start it to reach it.")
        #expect(await h.provider.starts == 0)
    }

    @Test func withStartWhenUsedOffAPromptIsRefusedAsToday() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        _ = try await h.call(DaemonAPI.Method.hostsSetWorkspaceOptions,
                             try JSONValue.encoding(DaemonAPI.HostWorkspaceOptions(host: h.devbox, startWhenUsed: false)))
        _ = await h.keeper()
        let phone = await h.connectClient()
        try phone.send(1, DaemonAPI.Method.agentsPrompt, try h.prompt("hello"), to: h.devbox)
        guard case .failure(_, let error) = try await phone.reply(1) else { Issue.record("answered"); return }
        #expect(error.code == DaemonAPI.Failure.hostOffline)
        #expect(await h.provider.starts == 0)
    }

    @Test func aFailedStartLeavesWhatWasKeptNotSentWithWhyAndTryAgainStartsAgain() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        await h.provider.set(failStart: "Error: droplet is locked")
        let kept = await h.keeper()
        let error = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("go"),
                                    from: h.caller)
        let id = try #require(try error?.data?.decode(DaemonAPI.KeptRequest.self).id)
        for _ in 0..<300 where await kept.all().first?.failed == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await kept.all().first?.failed == "Couldn’t start devbox: Error: droplet is locked")

        await h.provider.set()
        _ = try await h.call(DaemonAPI.Method.hostsRetryKept,
                             try JSONValue.encoding(DaemonAPI.KeptRequestID(host: h.devbox, id: id)))
        #expect(await kept.all().first?.failed == nil)
        _ = try await h.waitFor("starting") { $0.workspace?.phase == "connecting" }
        #expect(await h.provider.starts == 2)
    }

    @Test func aPromptTheHostRefusesIsShownNotSentInItsWords() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let kept = await h.keeper()
        _ = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("go"), from: h.caller)
        let (ours, theirs) = PairedTransport.pair()
        let host = KeptHost(transport: theirs)
        host.refuse = "Its folder has gone."
        await h.router.attachHost(h.devbox, transport: ours)
        for _ in 0..<300 where await kept.all().first?.failed == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await kept.all().first?.failed == "Its folder has gone.")
    }

    @Test func aRemovedHostTakesWhatWasKeptForIt() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let kept = await h.keeper()
        _ = await kept.keep(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("go"), from: h.caller)
        await kept.forget(h.devbox)
        #expect(await kept.all().isEmpty)
        #expect(try await h.store.list(prefix: KeptRequests.prefix).isEmpty)
    }
}

@Suite("Kept through the control plane's own method (#691 US3)")
struct KeepMethodTests {
    @Test func aClientWhoseHostLinkClosedKeepsThroughTheControlPlane() async throws {
        let h = try await ProviderHarness()
        try await h.link(try await h.add())
        let kept = await h.keeper()
        let keep = DaemonAPI.KeepRequest(host: h.devbox, method: DaemonAPI.Method.agentsPrompt, params: try h.prompt("hello"))
        do {
            _ = try await h.call(DaemonAPI.Method.hostsKeep, try JSONValue.encoding(keep))
            Issue.record("answered")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.kept)
        }
        #expect(await kept.all().map(\.text) == ["hello"])

        // Any other method is the host's own, and is refused.
        let read = DaemonAPI.KeepRequest(host: h.devbox, method: DaemonAPI.Method.agentsTranscript, params: [:])
        do {
            _ = try await h.call(DaemonAPI.Method.hostsKeep, try JSONValue.encoding(read))
            Issue.record("answered")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.hostOffline)
        }
    }
}
