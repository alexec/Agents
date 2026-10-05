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
    func host(in root: URL, key: Data, membershipFile: URL? = nil) -> Host {
        let said = Said()
        let hello = DaemonAPI.HostHello(host: .mac, version: "1", platform: "macOS arm64", machineID: "m", name: "This Mac")
        let dialer = HostDialer(membershipFile: membershipFile ?? root.appendingPathComponent("control-host.json"),
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

    // MARK: A join the disk refuses (#212)

    /// A folder this may not write to, standing in for a full disk: the membership's.
    func refusing(_ root: URL) throws -> URL {
        let folder = root.appendingPathComponent("refused", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        return folder
    }

    func allow(_ folder: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Joined and not saved: it dials anyway, says why, keeps the code, and saves (and only
    /// then spends the code) once the disk takes it.
    @Test func aJoinTheDiskRefusesIsDialledAndSavedOnceThereIsSpace() async throws {
        let root = try root()
        let refused = try refusing(root)
        defer { try? allow(refused); try? FileManager.default.removeItem(at: root) }
        let port = try await freePort()
        let service = try service(port: port, store: MemoryStore())
        try await service.start()
        defer { Task { await service.stop() } }
        let codeFile = root.appendingPathComponent("control-join-code")
        try Data(try await service.codes.issue(.host).text.utf8).write(to: codeFile)
        let membershipFile = refused.appendingPathComponent("control-host.json")

        let host = host(in: root, key: ControlAgreement.generate().privateKey, membershipFile: membershipFile)
        host.uplink.start()
        defer { host.uplink.stop() }
        await eventually { await service.router.state(of: .mac)?.isOnline == true }
        #expect(host.dialer.isMember)
        #expect(FileManager.default.fileExists(atPath: codeFile.path), "the code is kept until the join is saved")
        #expect(!FileManager.default.fileExists(atPath: membershipFile.path))
        #expect(host.said.statuses.contains { $0.problem?.contains("this host's membership could not be saved") == true })

        try allow(refused)
        let again = try await host.dialer.dial()
        again.close()
        #expect(ControlMembership.load(membershipFile)?.host == .mac)
        #expect(!FileManager.default.fileExists(atPath: codeFile.path))
    }

    /// A restart before the join was saved joins again with the same code and key, and is
    /// the same host, not a second one, and not refused as spent.
    @Test func aRestartBeforeTheJoinWasSavedJoinsAgainAsTheSameHost() async throws {
        let root = try root()
        let refused = try refusing(root)
        defer { try? allow(refused); try? FileManager.default.removeItem(at: root) }
        let port = try await freePort()
        let service = try service(port: port, store: MemoryStore())
        try await service.start()
        defer { Task { await service.stop() } }
        let codeFile = root.appendingPathComponent("control-join-code")
        try Data(try await service.codes.issue(.host).text.utf8).write(to: codeFile)
        let membershipFile = refused.appendingPathComponent("control-host.json")
        let key = ControlAgreement.generate().privateKey

        let first = host(in: root, key: key, membershipFile: membershipFile)
        first.uplink.start()
        await eventually { await service.router.state(of: .mac)?.isOnline == true }
        first.uplink.stop()
        await eventually { await service.router.state(of: .mac)?.isOnline == false }

        try allow(refused)
        let again = host(in: root, key: key, membershipFile: membershipFile)
        again.uplink.start()
        defer { again.uplink.stop() }
        await eventually { await service.router.state(of: .mac)?.isOnline == true }
        #expect(await service.records.hosts.count == 1)
        #expect(ControlMembership.load(membershipFile)?.host == .mac)
        #expect(!FileManager.default.fileExists(atPath: codeFile.path))
        #expect(!again.said.statuses.contains { $0.problem?.contains("used already") == true })
    }

    /// The same key is the same join while the code lasts; any other key is refused.
    @Test func aSpentCodeIsTheSameJoinOnlyForTheKeyThatSpentIt() async throws {
        let service = try service(port: try await freePort(), store: MemoryStore())
        let codes = service.codes
        let made = try #require(ControlCode(text: try await codes.issue(.host).text))
        let id = try #require(ControlAuth.codeID(secret: made.secret))
        let key = Data(repeating: 1, count: 32)
        let first = try await codes.spend(id, by: .init(publicKey: key, host: .mac))
        #expect(!first.replayed)
        let replayed = try await codes.spend(id, by: .init(publicKey: key, host: HostID.make()))
        #expect(replayed.replayed && replayed.host == .mac, "given what it was given the first time")
        await #expect(throws: ControlAuth.Refusal.self) {
            _ = try await codes.spend(id, by: .init(publicKey: Data(repeating: 2, count: 32), host: .mac))
        }
        await #expect(throws: ControlAuth.Refusal.self) { _ = try await codes.stored(id) }
        #expect(try await codes.stored(id, spentToo: true).purpose == .host)
    }

    /// A window or phone that paired and could not keep it pairs again with the same code
    /// as the same client, though it made a new id.
    @Test func aClientPairingAgainWithItsSpentCodeIsTheSameClient() async throws {
        let port = try await freePort()
        let service = try service(port: port, store: MemoryStore())
        try await service.start()
        defer { Task { await service.stop() } }
        let code = try #require(ControlCode(text: try await service.codes.issue(.client).text))
        let key = ControlAgreement.generate().privateKey
        let first = try await ControlCodeUse.pairClient(code, privateKey: key, id: UUID(), name: "phone",
                                                        kind: .iPhone, dial: ControlJoin.nio)
        let again = try await ControlCodeUse.pairClient(code, privateKey: key, id: UUID(), name: "phone",
                                                        kind: .iPhone, dial: ControlJoin.nio)
        #expect(again.client == first.client)
        #expect(await service.records.clients.count == 1)
        await #expect(throws: (any Error).self) {
            _ = try await ControlCodeUse.pairClient(code, privateKey: ControlAgreement.generate().privateKey, id: UUID(),
                                                    name: "another", kind: .iPhone, dial: ControlJoin.nio)
        }
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
