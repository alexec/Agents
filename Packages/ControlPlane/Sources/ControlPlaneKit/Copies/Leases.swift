import AgentsKitCore
import Foundation

/// Which copy holds each host's uplink (058, T063; data-model.md "Lease").
///
/// - A host's uplink authenticated here: create the lease (`absent`), or take over the one
///   there (`matching`, epoch + 1). A host that dialled this copy has left the other.
/// - Renewed every 10 s with `matching`. A renewal refused means another copy took the host:
///   this copy closes its uplink and says `gone`.
/// - The uplink ending here: the lease is marked expired, so no copy routes to it.
public actor Leases {
    struct Held {
        var etag: String
        var lease: HostLease
    }

    let store: any ControlStore
    let copy: String
    private var held: [HostID: Held] = [:]
    private var renewer: Task<Void, Never>?
    /// Another copy has the host now.
    private var lost: (@Sendable (HostID, Int) async -> Void)?

    public init(store: any ControlStore, copy: String) {
        self.store = store
        self.copy = copy
    }

    static func key(_ host: HostID) -> String { "v1/leases/\(host.rawValue).json" }

    public func onLost(_ lost: @escaping @Sendable (HostID, Int) async -> Void) { self.lost = lost }

    public func start(every interval: TimeInterval = HostLease.renewEvery) {
        renewer?.cancel()
        renewer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                await self?.renewAll()
            }
        }
    }

    public func stop() {
        renewer?.cancel()
        renewer = nil
    }

    /// Takes the host's lease for this copy. Returns its epoch.
    @discardableResult
    public func take(_ host: HostID) async throws -> Int {
        for _ in 0..<3 {
            let key = Self.key(host)
            let existing = try await store.get(key)
            let previous = existing.flatMap { try? ControlRecords.decoder.decode(HostLease.self, from: $0.data) }
            let lease = HostLease(host: host, copy: copy, epoch: (previous?.epoch ?? 0) + 1,
                                  expires: Date().addingTimeInterval(HostLease.lifetime))
            do {
                let etag = try await store.put(key, try ControlRecords.encoder.encode(lease),
                                               when: existing.map { .matching($0.etag) } ?? .absent)
                held[host] = Held(etag: etag, lease: lease)
                return lease.epoch
            } catch StoreError.conflict {
                continue
            }
        }
        throw StoreError.conflict(key: Self.key(host))
    }

    /// The uplink here ended: the lease is marked over, if it is still this copy's.
    public func release(_ host: HostID) async -> Int? {
        guard let mine = held.removeValue(forKey: host) else { return nil }
        var over = mine.lease
        over.expires = Date()
        _ = try? await store.put(Self.key(host), try ControlRecords.encoder.encode(over), when: .matching(mine.etag))
        return over.epoch
    }

    public func epoch(of host: HostID) -> Int? { held[host]?.lease.epoch }

    /// Who holds a host now, if anyone: the lease as stored, unless it has run out.
    public func holder(of host: HostID) async -> HostLease? {
        guard let object = try? await store.get(Self.key(host)),
              let lease = try? ControlRecords.decoder.decode(HostLease.self, from: object.data),
              lease.expires > Date() else { return nil }
        return lease
    }

    func renewAll() async {
        for (host, mine) in held {
            var renewed = mine.lease
            renewed.expires = Date().addingTimeInterval(HostLease.lifetime)
            do {
                let etag = try await store.put(Self.key(host), try ControlRecords.encoder.encode(renewed),
                                               when: .matching(mine.etag))
                held[host] = Held(etag: etag, lease: renewed)
            } catch StoreError.conflict {
                held[host] = nil
                await lost?(host, mine.lease.epoch)
            } catch {
                // The store is away: keep the uplink, and try again next time. Live work
                // carries on while the store is down (US3-6).
            }
        }
    }
}
