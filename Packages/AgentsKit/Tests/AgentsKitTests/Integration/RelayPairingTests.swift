import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A device announcing on the direct link is handed the Mac's relay key, which is all
/// pairing for the relay is (046, D1, contracts/daemon.md); and a paired device can be
/// forgotten from the Mac, and only from the Mac (R11).
@Suite("Pairing for the relay, and forgetting")
struct RelayPairingTests {
    struct Setup {
        let core: DaemonCore
        let locations: StoreLocations
    }

    private func setUp(root: URL? = nil) async throws -> Setup {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-pair-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return Setup(core: core, locations: locations)
    }

    private let macKey = DeviceKey.ephemeral().publicKey
    private let phoneKey = DeviceKey.ephemeral().publicKey

    private func call(_ setup: Setup, _ method: String, _ params: some Encodable,
                      from surface: Surface? = nil) async -> Result<JSONValue, JSONRPCError> {
        await setup.core.handle(method: method, params: try? JSONValue.encoding(params), from: surface, connection: UUID())
    }

    private func announce(_ setup: Setup, id: UUID = UUID()) async throws -> DaemonAPI.AnnounceReply {
        try await call(setup, DaemonAPI.Method.devicesAnnounce,
                       DaemonAPI.DeviceAnnouncement(id: id, publicKey: phoneKey, name: "Alex's iPhone", kind: .iPhone))
            .get().decode(DaemonAPI.AnnounceReply.self)
    }

    @Test func aDeviceAnnouncingIsHandedTheMacsKey() async throws {
        let setup = try await setUp()
        _ = try await call(setup, DaemonAPI.Method.relayRegister, DaemonAPI.RelayRegistration(publicKey: macKey)).get()
        let reply = try await announce(setup)
        #expect(reply.macKey == macKey)
        #expect(reply.device.name == "Alex's iPhone")
        #expect(reply.device.unknownFields["macKey"] == nil)
    }

    @Test func withNoBridgeThereIsNoKeyToHand() async throws {
        let setup = try await setUp()
        #expect(try await announce(setup).macKey == nil)
    }

    @Test func aKeyOfTheWrongShapeIsRefused() async throws {
        let setup = try await setUp()
        let result = await call(setup, DaemonAPI.Method.relayRegister, DaemonAPI.RelayRegistration(publicKey: Data([1, 2, 3])))
        #expect(throws: JSONRPCError.self) { try result.get() }
        #expect(try await announce(setup).macKey == nil)
    }

    @Test func theKeyOutlivesTheDaemon() async throws {
        let first = try await setUp()
        _ = try await call(first, DaemonAPI.Method.relayRegister, DaemonAPI.RelayRegistration(publicKey: macKey)).get()
        let second = try await setUp(root: first.locations.root)
        #expect(try await announce(second).macKey == macKey)
    }

    @Test func aPhoneFromBeforeTheRelayStillReadsTheReply() async throws {
        let setup = try await setUp()
        _ = try await call(setup, DaemonAPI.Method.relayRegister, DaemonAPI.RelayRegistration(publicKey: macKey)).get()
        let id = UUID()
        let raw = try await call(setup, DaemonAPI.Method.devicesAnnounce,
                                 DaemonAPI.DeviceAnnouncement(id: id, publicKey: phoneKey, name: "Old", kind: .iPhone)).get()
        let old = try raw.decode(Device.self)
        #expect(old.id == id)
        #expect(old.publicKey == phoneKey)
    }

    // MARK: Forgetting (046 US5)

    @Test func aForgottenDeviceIsGoneAndSaidToBe() async throws {
        let setup = try await setUp()
        let surface = FakeSurfaceRecorder()
        await setup.core.setBroadcaster { method, params in surface.record(method, params) }
        let id = UUID()
        _ = try await announce(setup, id: id)
        _ = try await call(setup, DaemonAPI.Method.devicesForget, DaemonAPI.DeviceForget(id: id), from: .mac).get()
        let listed = try await call(setup, DaemonAPI.Method.devicesList, Optional<String>.none).get().decode([Device].self)
        #expect(listed.isEmpty)
        let removal = surface.notifications(DaemonAPI.Notification.deviceChanged)
            .compactMap { try? $0?.decode(DaemonAPI.DeviceNotification.self) }
            .last
        #expect(removal?.id == id)
        #expect(removal?.removed == true)
        #expect(removal?.device == nil)
    }

    @Test func forgettingTwiceIsForgettingOnce() async throws {
        let setup = try await setUp()
        let id = UUID()
        _ = try await announce(setup, id: id)
        _ = try await call(setup, DaemonAPI.Method.devicesForget, DaemonAPI.DeviceForget(id: id)).get()
        _ = try await call(setup, DaemonAPI.Method.devicesForget, DaemonAPI.DeviceForget(id: id)).get()
    }

    @Test func aDeviceCannotForget() async throws {
        let setup = try await setUp()
        let id = UUID()
        _ = try await announce(setup, id: id)
        let result = await call(setup, DaemonAPI.Method.devicesForget, DaemonAPI.DeviceForget(id: id), from: .device(id))
        #expect(throws: JSONRPCError.self) { try result.get() }
        if case .failure(let error) = result { #expect(error.code == DaemonAPI.Failure.notAllowed) }
        let listed = try await call(setup, DaemonAPI.Method.devicesList, Optional<String>.none).get().decode([Device].self)
        #expect(listed.map(\.id) == [id])
    }

    @Test func aForgottenDeviceBackHomePairsAgain() async throws {
        let setup = try await setUp()
        _ = try await call(setup, DaemonAPI.Method.relayRegister, DaemonAPI.RelayRegistration(publicKey: macKey)).get()
        let id = UUID()
        _ = try await announce(setup, id: id)
        _ = try await call(setup, DaemonAPI.Method.devicesForget, DaemonAPI.DeviceForget(id: id)).get()
        let again = try await announce(setup, id: id)
        #expect(again.device.id == id)
        #expect(again.macKey == macKey)
    }
}

/// What a core broadcast, for a test to look at.
final class FakeSurfaceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [(String, JSONValue?)] = []

    func record(_ method: String, _ params: JSONValue?) {
        lock.lock(); heard.append((method, params)); lock.unlock()
    }

    func notifications(_ method: String) -> [JSONValue?] {
        lock.lock(); defer { lock.unlock() }
        return heard.filter { $0.0 == method }.map(\.1)
    }
}
