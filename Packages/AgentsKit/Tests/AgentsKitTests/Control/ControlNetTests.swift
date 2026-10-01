import Foundation
import LinuxControlDial
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The control plane on the network, for real: TLS-PSK on loopback, codes, pairing,
/// enrolment, and a call from a paired window through to an enrolled host (058, T018–T023).
@Suite("The control plane over the network", .serialized, .timeLimit(.minutes(1)))
struct ControlNetTests {
    struct Plane {
        let plane: ControlPlane
        let root: URL
        let net: ControlNet
    }

    func plane() async throws -> Plane {
        setenv("AGENTS_CONTROL_NO_BONJOUR", "1", 1)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cn-\(UUID().uuidString.prefix(6))")
        let port = Int.random(in: 20_000...40_000)
        let plane = ControlPlane(root: root, version: "test", port: port)
        try await plane.start()
        let net = try #require(plane.net)
        return Plane(plane: plane, root: root, net: net)
    }

    /// A host that answers every call with its name and the role it was asked with.
    func host(_ name: String, code: ControlCode) async throws -> (ControlUplink, ControlMembership) {
        let key = DeviceKey.ephemeral()
        let membership = try await ControlDialling.enroll(code, announce: DaemonAPI.HostAnnounce(
            publicKey: key.publicKey, name: name, platform: "test", version: "1", machineID: "m-\(name)"))
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
            .success(["host": .string(name), "method": .string(method), "role": .string(context.role.rawValue)])
        }
        let uplink = ControlUplink(server: server,
                                   hello: DaemonAPI.HostHello(version: "1", platform: "test", machineID: "m-\(name)", name: name),
                                   dial: ControlDialling.hostDial(membership, key: key))
        uplink.start()
        return (uplink, membership)
    }

    func code(_ shown: DaemonAPI.ControlCodeShown) throws -> ControlCode {
        try #require(ControlCode(text: shown.text))
    }

    @Test func aCodeReadsBackAsItWasWritten() throws {
        let code = ControlCode(purpose: .client(.operator), controlKey: Data([0x04] + Array(repeating: 7, count: 64)),
                               secret: Data(repeating: 9, count: 32), addresses: ["studio.local:8791", "127.0.0.1:8791"],
                               name: "Alex’s Mac: studio")
        #expect(ControlCode(text: code.text) == code)
        #expect(ControlCode(text: "  " + code.text + "\n") == code)
        #expect(ControlCode(text: "agents-pair:1:x:y:z") == nil)
    }

    @Test func aHostEnrolsAndAPairedWindowReachesItThroughTheControlPlane() async throws {
        let setup = try await plane()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let (uplink, membership) = try await host("devbox", code: code(await setup.net.startCode(.host, name: "cp")))
        defer { uplink.stop() }
        let hostID = try #require(membership.host)
        await eventually { await setup.plane.router.state(of: hostID)?.isOnline == true }

        let windowKey = DeviceKey.ephemeral()
        let window = try await ControlDialling.pair(code(await setup.net.startCode(.client(.operator), name: "cp")),
                                                    key: windowKey, id: UUID(), name: "Other Mac", kind: .mac)
        #expect(await setup.plane.methods.client(try #require(window.client))?.grant == .operator)

        let link = ControlLink(dial: ControlDialling.clientDial(window, key: windowKey))
        let client = DaemonClient(link: link.link(for: hostID))
        try await client.connect(startIfNeeded: false)
        let answer = try await client.call(DaemonAPI.Method.agentsList)
        #expect(answer["host"]?.stringValue == "devbox")
        #expect(answer["role"]?.stringValue == "control")

        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let status = try await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        #expect(status.you == window.client)
    }

    @Test func aCodeWorksOnce() async throws {
        let setup = try await plane()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let shown = try code(await setup.net.startCode(.client(.device), name: "cp"))
        _ = try await ControlDialling.pair(shown, key: .ephemeral(), id: UUID(), name: "iPad", kind: .iPad)
        await #expect(throws: (any Error).self) {
            _ = try await ControlDialling.pair(shown, key: .ephemeral(), id: UUID(), name: "Someone", kind: .mac)
        }
        #expect(await setup.plane.methods.allClients.count == 1)
    }

    @Test func aDevicePairedWithADeviceCodeIsRefusedWhatOnlyAnOperatorMayDo() async throws {
        let setup = try await plane()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let (uplink, membership) = try await host("devbox", code: code(await setup.net.startCode(.host, name: "cp")))
        defer { uplink.stop() }
        let hostID = try #require(membership.host)
        await eventually { await setup.plane.router.state(of: hostID)?.isOnline == true }

        let key = DeviceKey.ephemeral()
        let phone = try await ControlDialling.pair(code(await setup.net.startCode(.client(.device), name: "cp")),
                                                   key: key, id: UUID(), name: "iPhone", kind: .iPhone)
        let client = DaemonClient(link: ControlLink(dial: ControlDialling.clientDial(phone, key: key)).link(for: hostID))
        try await client.connect(startIfNeeded: false)
        #expect(try await client.call(DaemonAPI.Method.agentsList)["role"]?.stringValue == "device")
        do {
            _ = try await client.call(DaemonAPI.Method.credentialsLend)
            Issue.record("a device lent a credential")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notPermitted)
        }
    }

    @Test func aForgottenClientCannotComeBack() async throws {
        let setup = try await plane()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let key = DeviceKey.ephemeral()
        let window = try await ControlDialling.pair(code(await setup.net.startCode(.client(.operator), name: "cp")),
                                                    key: key, id: UUID(), name: "Other Mac", kind: .mac)
        let iPadKey = DeviceKey.ephemeral()
        let iPad = try await ControlDialling.pair(code(await setup.net.startCode(.client(.device), name: "cp")),
                                                  key: iPadKey, id: UUID(), name: "iPad", kind: .iPad)
        let iPadID = try #require(iPad.client)
        // It connects while it is paired.
        let before = try await ControlDialling.clientDial(iPad, key: iPadKey)()
        before.close()

        let control = DaemonClient(link: ControlLink(dial: ControlDialling.clientDial(window, key: key)).controlLink)
        try await control.connect(startIfNeeded: false)
        _ = try await control.call(DaemonAPI.Method.clientsForget, DaemonAPI.ClientRequest(client: iPadID))
        #expect(await setup.plane.methods.allClients.count == 1)
        await eventually { await !setup.net.listensFor(ControlKeys.clientIdentity(iPadID)) }
        await #expect(throws: (any Error).self) { _ = try await ControlDialling.clientDial(iPad, key: iPadKey)() }
    }

    /// The path Linux `agentsd --control` dials with: BoringSSL, and keys derived without CryptoKit.
    @Test func boringSSLEnrolsAndDialsTheMacListener() async throws {
        let setup = try await plane()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        let shown = try code(await setup.net.startCode(.host, name: "cp"))
        let privateKey = ControlAgreement.generate().privateKey
        let publicKey = try ControlAgreement.publicKey(privateKey: privateKey)
        let transport = try await LinuxControlDial.connect(
            shown.addresses, identity: ControlAgreement.codeIdentity(secret: shown.secret, host: true),
            key: ControlAgreement.codeKey(shown.secret))
        let announce = DaemonAPI.HostAnnounce(publicKey: publicKey, name: "linux", platform: "Linux arm64",
                                             version: "1", machineID: "linux-1")
        let request = try JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.hostsAnnounce,
                                                       params: try JSONValue.encoding(announce)))
        try transport.write(line: request)
        var incoming = transport.lines().makeAsyncIterator()
        let line = try #require(try await incoming.next())
        guard case .success(_, let result) = try JSONRPCCodec.decode(line: line) else {
            Issue.record("enrolment was refused: \(line)")
            return
        }
        transport.close()
        let host = try #require(try result.decode(DaemonAPI.Admitted.self).host)
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { _, _, _ in .success([:]) }
        let uplink = ControlUplink(server: server, hello: DaemonAPI.HostHello(
            version: "1", platform: "Linux arm64", machineID: "linux-1", name: "linux")) {
            let psk = try ControlAgreement.hostKey(privateKey: privateKey, peer: shown.controlKey, host: host)
            return try await LinuxControlDial.connect(shown.addresses, identity: ControlAgreement.hostIdentity(host), key: psk)
        }
        uplink.start()
        defer { uplink.stop() }
        await eventually { await setup.plane.router.state(of: host)?.isOnline == true }
    }
}
