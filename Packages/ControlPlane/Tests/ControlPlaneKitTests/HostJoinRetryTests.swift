import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// This Mac's host and a control plane that isn't up yet (#113): the host code is kept
/// until a join has worked, the first join is tried again on the uplink's backoff, and the
/// host joins without a new code once the control plane comes up.
@Suite("A host's first join is tried again", .timeLimit(.minutes(1)))
struct HostJoinRetryTests {
    let control = ControlAgreement.generate()

    final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [DaemonAPI.HostJoinStatus] = []
        func add(_ status: DaemonAPI.HostJoinStatus) { lock.withLock { all.append(status) } }
        var statuses: [DaemonAPI.HostJoinStatus] { lock.withLock { all } }
    }

    struct Host {
        let dialer: HostDialer
        let uplink: ControlUplink
        let said: Said
    }

    func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("join-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `agentsd`'s join, as `Daemon` puts it together, with a short backoff.
    func host(in root: URL, key: Data) -> Host {
        let said = Said()
        let hello = DaemonAPI.HostHello(host: .mac, version: "1", platform: "macOS arm64", machineID: "m", name: "This Mac")
        let dialer = HostDialer(membershipFile: root.appendingPathComponent("control-host.json"),
                                codeFile: root.appendingPathComponent("control-join-code"), given: nil,
                                privateKey: key, hello: hello, say: { said.add($0) })
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { _, method, _ in
            .success(["method": .string(method)])
        }
        let uplink = ControlUplink(server: server, hello: hello, onChange: { dialer.connected($0) },
                                   backoff: Backoff(first: .milliseconds(100), longest: .milliseconds(400)),
                                   dial: { try await dialer.dial() })
        return Host(dialer: dialer, uplink: uplink, said: said)
    }

    func service(port: Int, store: any ControlStore) throws -> ControlService {
        try ControlService(.init(store: store, privateKey: control.privateKey, url: URL(string: "http://127.0.0.1:\(port)")!,
                                 bind: "127.0.0.1", port: port, name: "test", machineID: "m"))
    }

    @Test func aHostStartedBeforeItsControlPlaneJoinsOnceItIsUpWithTheSameCode() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try await freePort()
        let store = MemoryStore()
        let service = try service(port: port, store: store)
        // The code Agents Host leaves, made before anything listens.
        let code = try await service.codes.issue(.host).text
        let codeFile = root.appendingPathComponent("control-join-code")
        try Data(code.utf8).write(to: codeFile)

        let host = host(in: root, key: ControlAgreement.generate().privateKey)
        host.uplink.start()
        defer { host.uplink.stop() }

        // Nothing listens: it says so, keeps the code, and keeps trying.
        await eventually { host.said.statuses.count >= 3 }
        let failed = try #require(host.said.statuses.last)
        #expect(!failed.member && !failed.connected)
        #expect(failed.problem?.contains("nothing is listening at 127.0.0.1:\(port)") == true)
        #expect(failed.summary.hasPrefix("Couldn't join the control plane: nothing is listening"))
        #expect(failed.summary.hasSuffix("Trying again…"))
        #expect(FileManager.default.fileExists(atPath: codeFile.path))
        #expect(!host.dialer.isMember)

        // The control plane comes up: the same code joins it, and is spent.
        try await service.start()
        defer { Task { await service.stop() } }
        await eventually { await service.router.state(of: .mac)?.isOnline == true }
        #expect(host.dialer.isMember)
        #expect(!FileManager.default.fileExists(atPath: codeFile.path))
        await eventually { host.said.statuses.last?.connected == true }
        #expect(await service.records.hosts.count == 1)
    }

    /// Joined once, a restart dials as the host it became: no code, no second enrolment.
    @Test func aRestartAfterAJoinDialsAsTheSameHostWithNoCode() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try await freePort()
        let service = try service(port: port, store: MemoryStore())
        try await service.start()
        defer { Task { await service.stop() } }
        try Data(try await service.codes.issue(.host).text.utf8).write(to: root.appendingPathComponent("control-join-code"))
        let key = ControlAgreement.generate().privateKey

        let first = host(in: root, key: key)
        first.uplink.start()
        await eventually { await service.router.state(of: .mac)?.isOnline == true }
        first.uplink.stop()
        await eventually { await service.router.state(of: .mac)?.isOnline == false }

        let again = host(in: root, key: key)
        again.uplink.start()
        defer { again.uplink.stop() }
        await eventually { await service.router.state(of: .mac)?.isOnline == true }
        #expect(await service.records.hosts.count == 1)
        #expect(again.said.statuses.allSatisfy { $0.problem == nil })
    }

    /// A name nothing answers for, as `macos-<serial>.local` was on the Mac in the issue:
    /// said as that, not as NIO's error alone.
    @Test func aNameThatDoesNotResolveIsSaidInWords() async throws {
        do {
            _ = try await ControlDial.connect(URL(string: "https://no-such-mac-\(UUID().uuidString.prefix(8)).invalid:8791")!,
                                              timeout: .seconds(5))
            Issue.record("it connected")
        } catch {
            #expect("\(error)".contains("can't be found on this network"))
        }
    }

    /// The control plane beside this Mac's host says how its join stands in `control/status`.
    @Test func controlStatusCarriesThisMacsHostsJoin() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(HostJoinFile.name)
        HostJoinFile(pid: getpid(), status: .init(member: false, connected: false, problem: "nothing is listening at x:1"))
            .write(to: file)
        let port = try await freePort()
        var configuration = ControlService.Configuration(store: MemoryStore(), privateKey: control.privateKey,
                                                         url: URL(string: "http://127.0.0.1:\(port)")!,
                                                         bind: "127.0.0.1", port: port, name: "test", machineID: "m")
        configuration.thisMacHost = { HostJoinFile.read(file) }
        let service = try ControlService(configuration)
        try await service.start()
        defer { Task { await service.stop() } }
        let join = try #require(try await LoopbackListenerTests.status(of: service).thisMacHost)
        #expect(join.failed)
        #expect(join.summary == "Couldn't join the control plane: nothing is listening at x:1. Trying again…")
    }
}
