import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A device the Mac has not seen pairs only with the code the Mac is showing, once
/// (security review, Phase 3). Announcing on the home network is no longer enough.
@Suite("Pairing by the code on the Mac")
struct PairingCodeTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
    }

    struct Setup {
        let core: DaemonCore
        let clock: Clock
        let heard: FakeSurfaceRecorder
    }

    private let macKey = DeviceKey.ephemeral().publicKey
    private let phoneKey = DeviceKey.ephemeral().publicKey

    private func setUp(bridge: Bool = true) async throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let clock = Clock()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(), now: { clock.now })
        await core.loadFromDisk()
        let heard = FakeSurfaceRecorder()
        await core.setBroadcaster { method, params in heard.record(method, params) }
        let setup = Setup(core: core, clock: clock, heard: heard)
        if bridge {
            _ = try await call(setup, DaemonAPI.Method.relayRegister, DaemonAPI.RelayRegistration(publicKey: macKey)).get()
        }
        return setup
    }

    private func call(_ setup: Setup, _ method: String, _ params: some Encodable,
                      role: ConnectionRole = .control) async -> Result<JSONValue, JSONRPCError> {
        await setup.core.handle(method: method, params: try? JSONValue.encoding(params), connection: UUID(), role: role)
    }

    private func announce(_ setup: Setup, id: UUID, as role: ConnectionRole) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.devicesAnnounce,
                   DaemonAPI.DeviceAnnouncement(id: id, publicKey: phoneKey, name: "iPhone", kind: .iPhone), role: role)
    }

    private func startPairing(_ setup: Setup) async throws -> DaemonAPI.PairingCode {
        try await call(setup, DaemonAPI.Method.devicesStartPairing, Optional<String>.none).get()
            .decode(DaemonAPI.PairingCode.self)
    }

    private func current(_ setup: Setup) async throws -> DaemonAPI.PairingSecret {
        try await call(setup, DaemonAPI.Method.pairingCurrent, Optional<String>.none).get()
            .decode(DaemonAPI.PairingSecret.self)
    }

    private func refusal(_ result: Result<JSONValue, JSONRPCError>) -> Int? {
        if case .failure(let error) = result { return error.code }
        return nil
    }

    @Test func withNoBridgeThereIsNothingToPairWith() async throws {
        let setup = try await setUp(bridge: false)
        await #expect(throws: JSONRPCError.self) { try await startPairing(setup) }
    }

    @Test func aCodeCarriesTheMacsKeyAndASecretOfItsOwn() async throws {
        let setup = try await setUp()
        let first = try await startPairing(setup)
        let second = try await startPairing(setup)
        #expect(first.macKey == macKey)
        #expect(first.secret.count == 32)
        #expect(first.secret != second.secret)
        #expect(try await current(setup).secret == second.secret, "a new code replaces the one before")
        #expect(second.expires == setup.clock.now.addingTimeInterval(5 * 60))
    }

    @Test func theCodeReadsBackFromItsText() throws {
        let code = DaemonAPI.PairingCode(macKey: macKey, secret: Data(repeating: 7, count: 32),
                                         name: "Alex's MacBook Pro: 2", expires: .now)
        let read = try #require(DaemonAPI.PairingCode(text: code.text))
        #expect(read.macKey == macKey && read.secret == code.secret && read.name == code.name)
        #expect(DaemonAPI.PairingCode(text: "agents-pair:1:nope:nope:x") == nil)
        #expect(DaemonAPI.PairingCode(text: "https://example.com") == nil)
    }

    /// The hole this closes: anyone on the network announcing and being paired.
    @Test func aDevicesConnectionCannotPairANewDevice() async throws {
        let setup = try await setUp()
        _ = try await startPairing(setup)
        #expect(refusal(await announce(setup, id: UUID(), as: .device)) == DaemonAPI.Failure.notAllowed)
        #expect(try await call(setup, DaemonAPI.Method.devicesList, Optional<String>.none).get()
            .decode([Device].self).isEmpty)
    }

    @Test func theCodePairsOneDeviceAndIsSpent() async throws {
        let setup = try await setUp()
        _ = try await startPairing(setup)
        let first = UUID()
        let reply = try await announce(setup, id: first, as: .pairing).get().decode(DaemonAPI.AnnounceReply.self)
        #expect(reply.device.id == first)
        #expect(reply.macKey == macKey)
        #expect(try await current(setup).secret == nil, "the bridge lets the code go")
        #expect(refusal(await announce(setup, id: UUID(), as: .pairing)) == DaemonAPI.Failure.notAllowed,
                "a second phone on the same code is refused")
    }

    @Test func aCodeLeftOnTheScreenRunsOut() async throws {
        let setup = try await setUp()
        _ = try await startPairing(setup)
        setup.clock.advance(5 * 60 + 1)
        #expect(try await current(setup).secret == nil)
        #expect(refusal(await announce(setup, id: UUID(), as: .pairing)) == DaemonAPI.Failure.notAllowed)
    }

    @Test func closingTheSheetEndsTheCode() async throws {
        let setup = try await setUp()
        _ = try await startPairing(setup)
        _ = try await call(setup, DaemonAPI.Method.devicesStopPairing, Optional<String>.none).get()
        #expect(try await current(setup).secret == nil)
        #expect(refusal(await announce(setup, id: UUID(), as: .pairing)) == DaemonAPI.Failure.notAllowed)
    }

    /// Its name and kind follow it, over its own link, with no code.
    @Test func aPairedDeviceAnnouncesAgainOverItsOwnLink() async throws {
        let setup = try await setUp()
        _ = try await startPairing(setup)
        let id = UUID()
        _ = try await announce(setup, id: id, as: .pairing).get()
        #expect(refusal(await announce(setup, id: id, as: .device)) == nil)
    }

    /// A Remote paired through the control plane reaches this Mac on a channel the
    /// control plane opened and bound to it. Its announce records it here, so it is told
    /// things, rather than being refused as unpaired (#232). Its key still never changes.
    @Test func aDeviceTheControlPlaneVouchesForRecordsItself() async throws {
        let setup = try await setUp()
        let id = UUID()
        let reply = try await setup.core.handle(
            method: DaemonAPI.Method.devicesAnnounce,
            params: try JSONValue.encoding(DaemonAPI.DeviceAnnouncement(id: id, publicKey: phoneKey,
                                                                        name: "iPad", kind: .iPad)),
            connection: UUID(), role: .device, vouched: true).get().decode(DaemonAPI.AnnounceReply.self)
        #expect(reply.device.id == id)
        #expect(try await call(setup, DaemonAPI.Method.devicesList, Optional<String>.none).get()
            .decode([Device].self).map(\.id) == [id])
        let otherKey = DeviceKey.ephemeral().publicKey
        let rekeyed = await setup.core.handle(
            method: DaemonAPI.Method.devicesAnnounce,
            params: try JSONValue.encoding(DaemonAPI.DeviceAnnouncement(id: id, publicKey: otherKey,
                                                                        name: "iPad", kind: .iPad)),
            connection: UUID(), role: .device, vouched: true)
        #expect(refusal(rekeyed) == DaemonAPI.Failure.notSupported)
    }

    /// Only the uplink vouches: a channel it opens for a device says so, and one the
    /// bridge gives to a device never does.
    @Test func onlyAControlPlaneChannelIsVouchedFor() async throws {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var vouched: [Bool] = []
        }
        let seen = Seen()
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { context, method, _ in
            if method == DaemonAPI.Method.devicesAnnounce { seen.lock.withLock { seen.vouched.append(context.vouched) } }
            return .success([:])
        }
        let ipad = UUID()
        let announcement = try JSONValue.encoding(DaemonAPI.DeviceAnnouncement(id: ipad, publicKey: phoneKey,
                                                                               name: "iPad", kind: .iPad))
        let (uplinkOurs, uplinkTheirs) = PairedTransport.pair()
        server.acceptVirtual(uplinkOurs, device: ipad)
        let fromUplink = JSONRPCConnection(transport: uplinkTheirs)
        await fromUplink.start()
        try await fromUplink.call(DaemonAPI.Method.devicesAnnounce, announcement)

        let (bridgeOurs, bridgeTheirs) = PairedTransport.pair()
        server.acceptVirtual(bridgeOurs, device: nil)
        let fromBridge = JSONRPCConnection(transport: bridgeTheirs)
        await fromBridge.start()
        try await fromBridge.call(DaemonAPI.Method.connectionBindDevice,
                                  try JSONValue.encoding(DaemonAPI.DeviceBinding(id: nil)))
        try await fromBridge.call(DaemonAPI.Method.devicesAnnounce, announcement)

        #expect(seen.lock.withLock { seen.vouched } == [true, false])
    }

    /// Forgetting ends what the device has open now, not only what it opens next.
    @Test func forgettingADeviceClosesItsConnections() async throws {
        let setup = try await setUp()
        final class Asked: @unchecked Sendable {
            let lock = NSLock()
            var wanted: [DaemonCore.AddressedBox.Wanted] = []
        }
        let asked = Asked()
        await setup.core.setConnectionCloser { wanted in asked.lock.withLock { asked.wanted.append(wanted) } }
        _ = try await startPairing(setup)
        let id = UUID()
        _ = try await announce(setup, id: id, as: .pairing).get()
        _ = try await call(setup, DaemonAPI.Method.devicesForget, DaemonAPI.DeviceForget(id: id)).get()

        let wanted = try #require(asked.lock.withLock { asked.wanted.first })
        #expect(wanted(DaemonServer.ConnectionContext(id: UUID(), surface: .device(id), role: .device)))
        #expect(!wanted(DaemonServer.ConnectionContext(id: UUID(), surface: .device(UUID()), role: .device)))
        #expect(!wanted(DaemonServer.ConnectionContext(id: UUID(), surface: .mac)))
    }

    /// The bridge rebuilds its listener on this, so the code's key is taken while it is
    /// good and not after.
    @Test func theBridgeIsToldWhenTheCodeBeginsAndEnds() async throws {
        let setup = try await setUp()
        _ = try await startPairing(setup)
        #expect(setup.heard.notifications(DaemonAPI.Notification.pairingChanged).count == 1)
        _ = try await announce(setup, id: UUID(), as: .pairing).get()
        #expect(setup.heard.notifications(DaemonAPI.Notification.pairingChanged).count == 2)
    }
}
