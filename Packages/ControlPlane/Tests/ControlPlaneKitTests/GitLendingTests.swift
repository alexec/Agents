import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// A Mac's git access lent to a host through the control plane (#1122): asked of every
/// client once per host and git server, read from the Mac only for a lend a person allowed,
/// and refused at once while the Mac is away.
@Suite("Git access lent between hosts", .serialized, .timeLimit(.minutes(2)))
struct GitLendingTests {
    let base = ControlServiceTests()
    static let secret = "gho_" + "FAKEFAKEFAKEFAKE1234"

    struct Setup {
        let running: ControlServiceTests.Running
        let mac: HostID
        let macUplink: ControlUplink
        let box: HostID
        let boxUplink: ControlUplink
        let control: DaemonClient
        let link: ControlLink
        let filled: Counter

        func stop() {
            link.disconnect()
            macUplink.stop()
            boxUplink.stop()
            Task { await running.service.stop() }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    func setUp() async throws -> Setup {
        let running = try await base.start()
        let (mac, macUplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text,
                                                   name: "Alex's Mac", platform: "macOS arm64")
        let filled = Counter()
        // The Mac's git: access to github.com only.
        macUplink.setControlAnswers { method, params in
            filled.add()
            let request = try #require(try params?.decode(DaemonAPI.GitCredentialRequest.self))
            guard method == DaemonAPI.Method.gitFill, request.host == "github.com" else {
                throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "This Mac has no git access to \(request.host).")
            }
            return try JSONValue.encoding(DaemonAPI.GitCredential(username: "x-access-token", password: Self.secret))
        }
        let (box, boxUplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        await eventually { await running.service.router.state(of: mac)?.isOnline == true }
        await eventually { await running.service.router.state(of: box)?.isOnline == true }
        let (_, link) = try await base.client(at: running.url, code: try await running.service.codes.issue(.client).text)
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        return Setup(running: running, mac: mac, macUplink: macUplink, box: box, boxUplink: boxUplink,
                     control: control, link: link, filled: filled)
    }

    func ask(_ setup: Setup, _ server: String = "github.com", protocol: String = "https") async throws -> DaemonAPI.GitCredential {
        try await setup.boxUplink.ask(DaemonAPI.Method.gitCredential, try JSONValue.encoding(
            DaemonAPI.GitCredentialRequest(protocol: `protocol`, host: server))).decode(DaemonAPI.GitCredential.self)
    }

    func row(_ setup: Setup) async throws -> DaemonAPI.ControlHost? {
        let hosts = try await setup.control.call(DaemonAPI.Method.hostsList).decode([DaemonAPI.ControlHost].self)
        return hosts.first { $0.id == setup.box }
    }

    func lend(_ setup: Setup, _ server: String = "github.com", allowed: Bool) async throws {
        _ = try await setup.control.call(DaemonAPI.Method.hostsLendGit,
                                         DaemonAPI.LendGit(host: setup.box, from: setup.mac, server: server, allowed: allowed))
    }

    @Test func theFirstAskWaitsForAPersonThenTheLendIsKept() async throws {
        let setup = try await setUp()
        defer { setup.stop() }

        let asked = Task { try await ask(setup) }
        // Every client sees the ask on the host's row, naming the Mac that would lend.
        var waiting: [DaemonAPI.GitAsk]?
        for _ in 0..<50 where waiting == nil {
            waiting = try await row(setup)?.gitAsks
            if waiting == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(waiting == [DaemonAPI.GitAsk(server: "github.com", from: setup.mac)])
        #expect(setup.filled.count == 0)

        try await lend(setup, allowed: true)
        let credential = try await asked.value
        #expect(credential.password == Self.secret)
        #expect(!"\(credential)".contains(Self.secret))
        #expect(try await row(setup)?.gitAsks == nil)
        #expect(try await row(setup)?.gitFrom == ["github.com": setup.mac])

        // Kept: the next git command, a push say, asks nobody.
        #expect(try await ask(setup).username == "x-access-token")
        #expect(setup.filled.count == 2)

        // Nothing of it is kept on the control plane.
        let records = await setup.running.service.records.hosts
        #expect(!String(describing: records).contains(Self.secret))
    }

    @Test func aServerTheMacHasNoAccessToFailsInPlainWords() async throws {
        let setup = try await setUp()
        defer { setup.stop() }
        try await lend(setup, "gitlab.com", allowed: true)
        do {
            _ = try await ask(setup, "gitlab.com")
            Issue.record("lent a credential the Mac does not have")
        } catch let error as JSONRPCError {
            #expect(error.message == "Alex's Mac has no git access to gitlab.com.")
        }
    }

    @Test func dontAllowFailsTheWaitingCommandAndRevokeTakesItBack() async throws {
        let setup = try await setUp()
        defer { setup.stop() }

        let asked = Task { try await ask(setup) }
        await eventually { (try? await row(setup)?.gitAsks) != nil }
        try await lend(setup, allowed: false)
        await #expect(throws: JSONRPCError.self) { _ = try await asked.value }
        #expect(try await row(setup)?.gitFrom == nil)

        try await lend(setup, allowed: true)
        #expect(try await ask(setup).password == Self.secret)
        try await lend(setup, allowed: false)
        #expect(try await row(setup)?.gitFrom == nil)
        // Taken back: asked again, and a person who says nothing is a no.
        await setup.running.service.methods.setGitAskPatience(.milliseconds(300))
        await #expect(throws: JSONRPCError.self) { _ = try await ask(setup) }
        #expect(setup.filled.count == 1)
    }

    @Test func aMacThatIsNotConnectedFailsAtOnce() async throws {
        let setup = try await setUp()
        defer { setup.stop() }
        try await lend(setup, allowed: true)
        setup.macUplink.stop()
        await eventually { await setup.running.service.router.state(of: setup.mac)?.isOnline != true }
        let began = ContinuousClock.now
        do {
            _ = try await ask(setup)
            Issue.record("lent a credential with the Mac away")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.hostOffline)
            #expect(error.message.contains("not connected"))
        }
        #expect(ContinuousClock.now - began < .seconds(5))

        // With no lend and no Mac connected, nobody is asked.
        try await lend(setup, allowed: false)
        await #expect(throws: JSONRPCError.self) { _ = try await ask(setup) }
        #expect(try await row(setup)?.gitAsks == nil)
    }

    @Test func onlyHttpsIsLent() async throws {
        let setup = try await setUp()
        defer { setup.stop() }
        try await lend(setup, allowed: true)
        await #expect(throws: JSONRPCError.self) { _ = try await ask(setup, protocol: "http") }
        #expect(setup.filled.count == 0)
    }

    /// A client's channel to the Mac's host is no way to read its git access: `git/fill`
    /// is answered only on channel 0, which only the control plane writes.
    @Test func noClientCanAskTheMacForItsGitAccess() async throws {
        let setup = try await setUp()
        defer { setup.stop() }
        let toMac = DaemonClient(link: setup.link.link(for: setup.mac))
        try await toMac.connect(startIfNeeded: false)
        let answer = try await toMac.call(DaemonAPI.Method.gitFill,
                                          DaemonAPI.GitCredentialRequest(protocol: "https", host: "github.com"))
        // The test host answers every channel call with its method's name: never a credential.
        #expect(answer["password"] == nil)
        #expect(setup.filled.count == 0)
    }
}
