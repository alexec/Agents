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
