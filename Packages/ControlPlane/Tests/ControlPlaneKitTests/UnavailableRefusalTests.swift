import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// A control plane that cannot read its store says so, rather than that it does not
/// know the device: "unknown" made a phone forget its pairing over a moment's hiccup (#81).
@Suite("A store that cannot be read", .timeLimit(.minutes(2)))
struct UnavailableRefusalTests {
    let base = ControlServiceTests()

    /// A memory store that fails every call while `failing` is set.
    actor FlakyStore: ControlStore {
        let inner = MemoryStore()
        var failing = false
        func fail(_ on: Bool) { failing = on }
        struct Down: Error {}
        func get(_ key: String) async throws -> StoredObject? {
            if failing { throw Down() }
            return try await inner.get(key)
        }
        func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
            if failing { throw Down() }
            return try await inner.put(key, data, when: when)
        }
        func delete(_ key: String) async throws {
            if failing { throw Down() }
            try await inner.delete(key)
        }
        func list(prefix: String) async throws -> [StoredKey] {
            if failing { throw Down() }
            return try await inner.list(prefix: prefix)
        }
    }

    private func credentials(for id: UUID) throws -> ControlAuth.Credentials {
        let key = ControlAgreement.generate()
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: base.control.publicKey, client: id)
        return ControlAuth.Credentials(identity: .client(id), key: shared, kind: "iPhone", controlKey: base.control.publicKey)
    }

    @Test func aDeviceTheStoreCannotBeReadForIsToldToTryAgain() async throws {
        let store = FlakyStore()
        let running = try await base.start(store: store)
        defer { Task { await running.service.stop() } }
        await store.fail(true)
        await #expect(throws: ControlAuth.Refusal(.unavailable)) {
            _ = try await base.join(running.url, try credentials(for: UUID()))
        }
    }

    @Test func aDeviceTheStoreDoesNotHoldIsStillUnknown() async throws {
        let running = try await base.start(store: FlakyStore())
        defer { Task { await running.service.stop() } }
        await #expect(throws: ControlAuth.Refusal(.unknown)) {
            _ = try await base.join(running.url, try credentials(for: UUID()))
        }
    }
}
