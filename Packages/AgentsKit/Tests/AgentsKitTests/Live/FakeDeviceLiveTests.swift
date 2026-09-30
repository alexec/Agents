import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore
import ControlDial

/// A fake iPhone against a control plane, dialling exactly as the Remote does since 058's
/// US5 (T078): a version 2 device code, then the control plane's one address over
/// `URLSession`'s WebSocket with the pin from the code, and a key of its own.
///
///     AGENTS_FAKE_DEVICE_CODE='agents-control:2:c:device:…' swift test --filter FakeDeviceLiveTests
///
/// It pairs with the code; connects as the device; then says what it could and could not
/// do, the bare way (its connection's home host) and the wrapped way (every host).
///
/// With `AGENTS_FAKE_DEVICE_RELAY=1` and `AGENTS_RELAY_FOLDER` (the folder a scratch
/// `agents-relay` stands in for iCloud with), it then goes through the relay as the
/// Remote does when the address cannot be reached (T077), and, given a host code in
/// `AGENTS_FAKE_DEVICE_HOST_CODE`, raises a need as a host of its own and reads the
/// notice back from the mailbox with its key (T097).
@Suite("A fake iPhone through a control plane",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_CODE"] != nil),
       .serialized, .timeLimit(.minutes(30)))
struct FakeDeviceLiveTests {
    let codeText = ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_CODE"] ?? ""

    static let dial: ControlCodeUse.Dial = { url, pin in try await WebSocketLink.connect(url, pin: pin) }

    @Test func pairConnectAndSeeEveryHostAsADevice() async throws {
        // 1. Pair with the device code, as the Remote does after a scan.
        let code = try #require(ControlCode(text: codeText), "AGENTS_FAKE_DEVICE_CODE is not a code")
        let key = ControlAgreement.generate()
        let id = UUID()
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key.privateKey, id: id, name: "Fake iPhone",
                                                             kind: .iPhone, dial: Self.dial)
        print("fake-device: paired with \(code.name) as \(id)")

        // 2. Connect as the device: over WebSocketLink, with the pin.
        let dial = try ControlCodeUse.clientDial(membership, privateKey: key.privateKey, kind: "iphone", dial: Self.dial)
        let phone = DaemonClient(link: FixedLink(make: dial))
        try await phone.connect(startIfNeeded: false)

        // 3. Bare lines reach the home host, as a device.
        let status = try await phone.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        print("fake-device: control/status → \(status.name), home host \(status.homeHost?.rawValue ?? "-")")
        if status.homeHost != nil {
            let projects = try await phone.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                                returning: [DaemonAPI.ProjectSummary].self)
            print("fake-device: bare projects/list → \(projects.map(\.name))")
            do {
                _ = try await phone.call(DaemonAPI.Method.credentialsLend)
                Issue.record("the device lent a credential")
            } catch let error as JSONRPCError {
                #expect(error.code == DaemonAPI.Failure.notPermitted)
                print("fake-device: credentials/lend refused (\(error.code))")
            }
        }

        // 4. The wrapped wire, over one more connection: every host.
        let wrapped = ControlLink(dial: dial)
        let control = DaemonClient(link: wrapped.controlLink)
        try await control.connect(startIfNeeded: false)
        let hosts = try await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
        print("fake-device: hosts/list → \(hosts.map { "\($0.name) (\($0.id), \($0.state))" })")
        for host in hosts where host.state == "online" && host.relay != true {
            let there = DaemonClient(link: wrapped.link(for: host.id))
            try await there.connect(startIfNeeded: false)
            let listed = try await there.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                              returning: [DaemonAPI.ProjectSummary].self)
            print("fake-device: \(host.name) projects → \(listed.map(\.name))")
            do {
                _ = try await there.call(DaemonAPI.Method.runtimesInstall, ["runtime": "claude"])
                Issue.record("the device installed a runtime")
            } catch let error as JSONRPCError {
                print("fake-device: on \(host.id) an operator-only call was refused (\(error.code))")
            }
        }
        do {
            _ = try await control.call(DaemonAPI.Method.clientsList)
            Issue.record("the device listed clients")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.notPermitted)
            print("fake-device: clients/list refused by the control plane (\(error.code))")
        }
        wrapped.disconnect()
        await phone.disconnect()
        print("FAKE-DEVICE-ID \(id)")

        let environment = ProcessInfo.processInfo.environment
        guard environment["AGENTS_FAKE_DEVICE_RELAY"] == "1" else { return }
        try await throughTheRelay(membership: membership, privateKey: key.privateKey, id: id, status: status,
                                  folder: URL(fileURLWithPath: try #require(environment["AGENTS_RELAY_FOLDER"])),
                                  hostCode: environment["AGENTS_FAKE_DEVICE_HOST_CODE"])
    }

    /// 5–6. The same device through `agents-relay`, and a notice through its mailbox.
    func throughTheRelay(membership: ControlMembership, privateKey: Data, id: UUID, status: DaemonAPI.ControlStatus,
                         folder: URL, hostCode: String?) async throws {
        let relayKey = try #require(status.relayKey, "the control plane names no relay")
        print("fake-device: control/status names a relay (\(relayKey.base64EncodedString().prefix(12))…)")
        let relayed = try ControlCodeUse.relayedDial(membership, privateKey: privateKey, relayKey: relayKey,
                                                     channel: FolderRelayChannel(folder: folder))
        let away = DaemonClient(link: FixedLink(make: relayed))
        let started = Date()
        try await away.connect(startIfNeeded: false, timeout: .seconds(60))
        print("fake-device: through the relay in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        let there = try await away.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        #expect(there.you == id)
        print("fake-device: relayed control/status → \(there.name), you \(there.you?.uuidString.prefix(8) ?? "-")")
        if there.homeHost != nil {
            let projects = try await away.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(includeArchived: false),
                                               returning: [DaemonAPI.ProjectSummary].self)
            print("fake-device: relayed projects/list → \(projects.map(\.name))")
            do {
                _ = try await away.call(DaemonAPI.Method.credentialsLend)
                Issue.record("the device lent a credential through the relay")
            } catch let error as JSONRPCError {
                #expect(error.code == DaemonAPI.Failure.notPermitted)
                print("fake-device: relayed credentials/lend refused (\(error.code))")
            }
            // Away, and happy to be told: as the Remote says it.
            _ = try await away.call(DaemonAPI.Method.presenceReport,
                                    DaemonAPI.PresenceReport(watching: nil, active: false, mayNotify: true))
        }
        defer { Task { await away.disconnect() } }

        // 6. A need from a host, sealed by the relay to this device, read back with its key.
        guard let hostCode, let code = ControlCode(text: hostCode) else { return await hold() }
        let hostKey = ControlAgreement.generate()
        let hello = DaemonAPI.HostHello(version: "walk", platform: "fake", machineID: "fake-\(UUID().uuidString.prefix(8))",
                                        name: "fake host for a notice")
        let hostMembership = try await ControlJoin.enrollHost(code, privateKey: hostKey.privateKey, hello: hello)
        let uplink = try await ControlJoin.hostDial(hostMembership, privateKey: hostKey.privateKey)()
        defer { uplink.close() }
        try uplink.write(line: ControlWire.channel(0, message: JSONRPCCodec.encode(
            .request(id: .number(1), method: DaemonAPI.Method.hostHello, params: try JSONValue.encoding(hello)))))
        let need = Need(id: .permission(UUID()), agentID: UUID(), folder: URL(filePath: "/walk"), kind: .permission,
                        raisedAt: Date().addingTimeInterval(-600),
                        headline: Headline(h1: "walk5", h2: "A notice through the relay", h3: "may run a command"))
        try uplink.write(line: ControlWire.channel(0, message: JSONRPCCodec.encode(
            .request(id: .number(2), method: DaemonAPI.Method.attentionNeed,
                     params: try JSONValue.encoding(DaemonAPI.AttentionNeed.offer(need, buzz: true))))))
        let mailbox = FolderMailbox(folder: folder)
        let asked = Date()
        while mailbox.waiting(for: id).first(where: { $0.needID == need.id }) == nil, Date().timeIntervalSince(asked) < 30 {
            try await Task.sleep(for: .milliseconds(200))
        }
        let item = try #require(mailbox.waiting(for: id).first { $0.needID == need.id }, "no notice in the mailbox")
        let headline = try Envelope.open(try #require(item.envelope), with: try DeviceKey.software(privateKey: privateKey))
        print("fake-device: notice in \(String(format: "%.1f", Date().timeIntervalSince(asked))) s, alert \(item.alert), "
              + "opened with this device's key: \(headline.h1) · \(headline.h2)")
        #expect(headline.h2 == "A notice through the relay")
        let sealedText = (try? String(contentsOf: folder.appendingPathComponent("mailbox/\(id.uuidString)"), encoding: .utf8)) ?? ""
        #expect(!sealedText.contains("A notice through the relay"))

        try uplink.write(line: ControlWire.channel(0, message: JSONRPCCodec.encode(
            .request(id: .number(3), method: DaemonAPI.Method.attentionNeed,
                     params: try JSONValue.encoding(DaemonAPI.AttentionNeed.withdraw(need.id))))))
        let withdrawn = Date()
        while mailbox.waiting(for: id).first(where: { $0.needID == need.id })?.envelope != nil,
              Date().timeIntervalSince(withdrawn) < 30 {
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(mailbox.waiting(for: id).first { $0.needID == need.id }?.envelope == nil)
        print("fake-device: withdrawn in \(String(format: "%.1f", Date().timeIntervalSince(withdrawn))) s")
        print("FAKE-HOST-ID \(hostMembership.host?.rawValue ?? "-")")
        await hold()
    }

    /// `AGENTS_FAKE_DEVICE_HOLD=<seconds>`: stay connected through the relay that long, so a
    /// walk can look at the window meanwhile (frame N).
    func hold() async {
        guard let seconds = ProcessInfo.processInfo.environment["AGENTS_FAKE_DEVICE_HOLD"].flatMap(Double.init) else { return }
        print("fake-device: holding the relayed connection for \(Int(seconds)) s")
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The move's own live test (US7) still uses this name for the first build's link.
    typealias Fixed = FixedLink

    struct FixedLink: DaemonLink {
        let make: @Sendable () async throws -> any LineTransport
        func transport() async throws -> any LineTransport { try await make() }
        func start() async throws {}
    }
}
