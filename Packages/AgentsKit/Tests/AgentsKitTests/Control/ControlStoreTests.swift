import AgentsKitCore
import Foundation
import Testing

/// contracts/store.md, for the stores that live in the kit. The bucket runs the same
/// checks in ControlPlaneKitTests against MinIO.
@Suite("The control plane's store")
struct ControlStoreTests {
    static func folder() -> (FolderStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        return (FolderStore(root: root), root)
    }

    static func each(_ body: (any ControlStore) async throws -> Void) async throws {
        try await body(MemoryStore())
        let (store, root) = folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(store)
    }

    @Test func createOnlyConflictsTheSecondTime() async throws {
        try await Self.each { store in
            _ = try await store.put("v1/clients/a.json", Data("one".utf8), when: .absent)
            await #expect(throws: StoreError.conflict(key: "v1/clients/a.json")) {
                _ = try await store.put("v1/clients/a.json", Data("two".utf8), when: .absent)
            }
            #expect(try await store.get("v1/clients/a.json")?.data == Data("one".utf8))
        }
    }

    @Test func aStaleEntityTagConflictsAndChangesNothing() async throws {
        try await Self.each { store in
            let first = try await store.put("v1/hosts/h.json", Data("a".utf8), when: .absent)
            let second = try await store.put("v1/hosts/h.json", Data("b".utf8), when: .matching(first))
            #expect(first != second)
            await #expect(throws: StoreError.conflict(key: "v1/hosts/h.json")) {
                _ = try await store.put("v1/hosts/h.json", Data("c".utf8), when: .matching(first))
            }
            #expect(try await store.get("v1/hosts/h.json") == StoredObject(data: Data("b".utf8), etag: second))
        }
    }

    @Test func matchingAKeyThatIsGoneConflicts() async throws {
        try await Self.each { store in
            await #expect(throws: StoreError.conflict(key: "v1/leases/h.json")) {
                _ = try await store.put("v1/leases/h.json", Data("x".utf8), when: .matching("\"nope\""))
            }
        }
    }

    @Test func listSeesWhatIsUnderAPrefixAndNothingElse() async throws {
        try await Self.each { store in
            _ = try await store.put("v1/clients/a.json", Data("a".utf8), when: .absent)
            _ = try await store.put("v1/clients/b.json", Data("b".utf8), when: .absent)
            _ = try await store.put("v1/hosts/h.json", Data("h".utf8), when: .absent)
            let clients = try await store.list(prefix: "v1/clients/")
            #expect(clients.map(\.key) == ["v1/clients/a.json", "v1/clients/b.json"])
            try await store.delete("v1/clients/a.json")
            #expect(try await store.list(prefix: "v1/clients/").map(\.key) == ["v1/clients/b.json"])
            #expect(try await store.get("v1/clients/a.json") == nil)
        }
    }

    /// Rule 10: the same bytes keep the same tag, which is why every write bumps `rev`.
    @Test func theSameBytesKeepTheSameTag() async throws {
        try await Self.each { store in
            let a = try await store.put("v1/x.json", Data("A".utf8), when: .absent)
            let b = try await store.put("v1/x.json", Data("B".utf8), when: .matching(a))
            let again = try await store.put("v1/x.json", Data("A".utf8), when: .matching(b))
            #expect(again == a)
        }
    }

    /// A code is used once, however many copies race for it (US3-3).
    @Test func aSpentCodeIsWrittenOnceWhenTwentyRace() async throws {
        try await Self.each { store in
            let wins = await withTaskGroup(of: Bool.self) { group in
                for n in 0..<20 {
                    group.addTask {
                        (try? await store.put("v1/codes/c.spent", Data("\(n)".utf8), when: .absent)) != nil
                    }
                }
                return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            #expect(wins == 1)
        }
    }

    @Test func theProbePassesOnAStoreThatKeepsConditions() async throws {
        try await Self.each { store in try await store.probe(copy: "test") }
    }

    @Test func theProbeRefusesAStoreThatIgnoresConditions() async throws {
        await #expect(throws: StoreError.self) { try await Careless().probe(copy: "test") }
    }

    @Test func aFolderKeyCannotLeaveTheFolder() async throws {
        let (store, root) = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for key in ["../escape", "/etc/passwd", "v1/../../x", "v1/.hidden", ""] {
            await #expect(throws: StoreError.self) { _ = try await store.put(key, Data(), when: .always) }
        }
    }

    @Test func aStoreThatIsDownSaysSo() async throws {
        let store = MemoryStore()
        await store.setDown(true)
        await #expect(throws: StoreError.unavailable("the test turned it off")) {
            _ = try await store.get("v1/control.json")
        }
        #expect(StoreError.unavailable("x").rpcError.code == DaemonAPI.Failure.storeUnavailable)
        #expect(StoreError.conflict(key: "k").rpcError.code == DaemonAPI.Failure.changedElsewhere)
    }

    /// The control plane's failure codes are its own (main took -32070 and -32080).
    @Test func theControlPlanesFailureCodesClashWithNothingNearby() {
        let ours = [DaemonAPI.Failure.hostOffline, DaemonAPI.Failure.noSuchHost, DaemonAPI.Failure.lastOperator,
                    DaemonAPI.Failure.changedElsewhere, DaemonAPI.Failure.storeUnavailable]
        #expect(Set(ours).count == ours.count)
        #expect(!ours.contains(DaemonAPI.Failure.signInWanted))
        #expect(!ours.contains(DaemonAPI.Failure.catalogRefused))
    }
}

/// A bucket that ignores `If-None-Match` and `If-Match`.
private actor Careless: ControlStore {
    var objects: [String: Data] = [:]
    func get(_ key: String) async throws -> StoredObject? { objects[key].map { StoredObject(data: $0, etag: "\"\($0.count)\"") } }
    func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
        objects[key] = data
        return "\"\(data.count)-\(UUID().uuidString)\""
    }
    func delete(_ key: String) async throws { objects[key] = nil }
    func list(prefix: String) async throws -> [StoredKey] { [] }
}
