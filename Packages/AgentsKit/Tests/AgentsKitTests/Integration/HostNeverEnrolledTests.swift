import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A host started with no membership and no code (#303). It used to log one line and
/// return, so the window could not tell it from a host that was down, and Agents Host's
/// Try Again (a code left in the root, then a signal) had nothing listening for it.
@Suite("A host that never enrolled", .timeLimit(.minutes(1)))
struct HostNeverEnrolledTests {
    private final class Said: @unchecked Sendable {
        private let lock = NSLock()
        private var status: DaemonAPI.HostJoinStatus?
        func add(_ status: DaemonAPI.HostJoinStatus) { lock.withLock { self.status = status } }
        var last: DaemonAPI.HostJoinStatus? { lock.withLock { status } }
    }

    @Test func aDialWithNoCodeSaysTheHostHasNoMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("no-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let said = Said()
        let hello = DaemonAPI.HostHello(host: .mac, version: "1", platform: "macOS arm64", machineID: "m", name: "This Mac")
        let dialer = HostDialer(membershipFile: root.appendingPathComponent("control-host.json"),
                                codeFile: root.appendingPathComponent("control-join-code"), given: nil,
                                privateKey: Data(repeating: 1, count: 32), hello: hello, say: { said.add($0) })
        do {
            _ = try await dialer.dial()
            Issue.record("a host with no code dialled")
        } catch {
            #expect("\(error)".contains("no host code"))
        }
        let status = try #require(said.last)
        #expect(!status.member && !status.connected)
        #expect(status.problem?.contains("no host code") == true)
        #expect(status.failed)
    }

    /// A code left after the first dial is the one the next dial uses.
    @Test func aCodeLeftLaterIsTheOneTheNextDialUses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("later-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let said = Said()
        let hello = DaemonAPI.HostHello(host: .mac, version: "1", platform: "macOS arm64", machineID: "m", name: "This Mac")
        let codeFile = root.appendingPathComponent("control-join-code")
        let dialer = HostDialer(membershipFile: root.appendingPathComponent("control-host.json"),
                                codeFile: codeFile, given: nil,
                                privateKey: ControlAgreement.generate().privateKey, hello: hello, say: { said.add($0) })
        do { _ = try await dialer.dial() } catch {}
        #expect(said.last?.problem?.contains("no host code") == true)

        let code = ControlCode(purpose: .host, controlKey: ControlAgreement.generate().publicKey,
                               secret: Data(repeating: 2, count: 32), url: "wss://127.0.0.1:1", pin: nil, name: "test")
        try Data(code.text.utf8).write(to: codeFile)
        do { _ = try await dialer.dial() } catch {}
        let later = try #require(said.last?.problem)
        #expect(!later.contains("no host code"))
    }

    /// The daemon itself, not only the dialer: `join` used to return before any status
    /// was written when the root had no code.
    @Test func theDaemonWritesThatItHasNotEnrolled() async throws {
        let id = UUID().uuidString.prefix(8)
        let root = URL(fileURLWithPath: "/tmp/agt-ne-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = StoreLocations(root: root)
        let daemon = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher(),
                                control: Daemon.Control())
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }

        let status = try #require(await eventuallySome("the join file") {
            HostJoinFile.read(locations.controlJoinStatus)
        })
        #expect(!status.member && !status.connected)
        #expect(status.problem?.contains("no host code") == true)
    }
}
