import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// A renewal is written across an await, and the actor is entered again meanwhile (#206).
@Suite("Renewing leases", .timeLimit(.minutes(1)))
struct LeaseRenewalTests {
    /// A memory store whose next write waits, before or after it lands, until let go.
    actor HeldStore: ControlStore {
        let inner = MemoryStore()
        enum When { case before, after }
        private var hold: When?
        private var waiting: CheckedContinuation<Void, Never>?
        private var arrived: CheckedContinuation<Void, Never>?

        func holdNext(_ when: When) { hold = when }

        /// Returns once the held write is waiting.
        func held() async {
            if waiting != nil { return }
            await withCheckedContinuation { arrived = $0 }
        }

        func letGo() {
            waiting?.resume()
            waiting = nil
        }

        private func pause() async {
            await withCheckedContinuation { continuation in
                waiting = continuation
                arrived?.resume()
                arrived = nil
            }
        }

        func get(_ key: String) async throws -> StoredObject? { try await inner.get(key) }
        func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
            let now = hold
            hold = nil
            if now == .before { await pause() }
            let etag = try await inner.put(key, data, when: when)
            if now == .after { await pause() }
            return etag
        }
        func delete(_ key: String) async throws { try await inner.delete(key) }
        func list(prefix: String) async throws -> [StoredKey] { try await inner.list(prefix: prefix) }
    }

    final class Lost: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [HostID] = []
        func add(_ host: HostID) { lock.withLock { hosts.append(host) } }
        var all: [HostID] { lock.withLock { hosts } }
    }

    let host = HostID(rawValue: "h-1")

    @Test func aHostThatReconnectsDuringARenewalKeepsItsNewUplink() async throws {
        let store = HeldStore()
        let leases = Leases(store: store, copy: "a")
        let lost = Lost()
        await leases.onLost { host, _ in lost.add(host) }
        try await leases.take(host)
        await store.holdNext(.before)
        let renewing = Task { await leases.renewAll() }
        await store.held()
        // The host redials this copy while the renewal is out.
        let epoch = try await leases.take(host)
        await store.letGo()
        await renewing.value
        #expect(lost.all.isEmpty, "its new uplink is not closed as lost")
        #expect(await leases.epoch(of: host) == epoch)
        #expect(await leases.holder(of: host)?.epoch == epoch)
    }

    @Test func aLeaseReleasedDuringARenewalIsNotBroughtBack() async throws {
        for when in [HeldStore.When.before, .after] {
            let store = HeldStore()
            let leases = Leases(store: store, copy: "a")
            let lost = Lost()
            await leases.onLost { host, _ in lost.add(host) }
            try await leases.take(host)
            await store.holdNext(when)
            let renewing = Task { await leases.renewAll() }
            await store.held()
            _ = await leases.release(host)
            await store.letGo()
            await renewing.value
            #expect(lost.all.isEmpty, "\(when)")
            #expect(await leases.epoch(of: host) == nil, "\(when)")
            #expect(await leases.holder(of: host) == nil, "\(when): no copy holds it")
        }
    }

    /// One copy, as Agents Host runs: nobody to tell who holds a host, so no lease is written.
    @Test func aSingleCopyWritesNoLeases() async throws {
        let base = ControlServiceTests()
        let store = MemoryStore()
        let running = try await base.start(store: store)
        defer { Task { await running.service.stop() } }
        let (host, uplink) = try await base.host(at: running.url, code: try await running.service.codes.issue(.host).text)
        defer { uplink.stop() }
        await eventually { await running.service.router.state(of: host)?.isOnline == true }
        #expect(try await store.list(prefix: "v1/leases/").isEmpty)
    }
}
