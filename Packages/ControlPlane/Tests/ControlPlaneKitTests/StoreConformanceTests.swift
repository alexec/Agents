import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// Every store keeps the same promises (058, T034; contracts/store.md rules 4 and 8–11):
/// the memory and folder stores always, and a bucket when `AGENTS_TEST_S3` names one, as
/// `s3://bucket/prefix` with `AGENTS_STORE_ENDPOINT`, `AGENTS_STORE_PATH_STYLE` and the
/// usual AWS keys in the environment.
@Suite("Store conformance", .timeLimit(.minutes(2)))
struct StoreConformanceTests {
    enum Kind: String, CaseIterable, CustomTestStringConvertible {
        case memory, folder, bucket
        var testDescription: String { rawValue }
    }

    static var kinds: [Kind] {
        ProcessInfo.processInfo.environment["AGENTS_TEST_S3"] == nil ? [.memory, .folder] : Kind.allCases
    }

    /// A fresh, empty store of the kind: its own folder, or its own prefix in the bucket.
    static func make(_ kind: Kind) throws -> any ControlStore {
        switch kind {
        case .memory:
            return MemoryStore()
        case .folder:
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("conf-\(UUID().uuidString)")
            return FolderStore(root: root)
        case .bucket:
            let environment = ProcessInfo.processInfo.environment
            let text = environment["AGENTS_TEST_S3"]!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return try StoreAddress.open(text + "/conf-\(UUID().uuidString.prefix(8))", environment: environment)
        }
    }

    @Test(arguments: kinds)
    func createOnlyConflicts(_ kind: Kind) async throws {
        let store = try Self.make(kind)
        _ = try await store.put("v1/a.json", Data("1".utf8), when: .absent)
        await #expect(throws: StoreError.conflict(key: "v1/a.json")) {
            _ = try await store.put("v1/a.json", Data("2".utf8), when: .absent)
        }
        #expect(try await store.get("v1/a.json")?.data == Data("1".utf8))
    }

    @Test(arguments: kinds)
    func aStaleMatchingConflicts(_ kind: Kind) async throws {
        let store = try Self.make(kind)
        let first = try await store.put("v1/a.json", Data("1".utf8), when: .absent)
        let second = try await store.put("v1/a.json", Data("2".utf8), when: .matching(first))
        #expect(second != first)
        await #expect(throws: StoreError.conflict(key: "v1/a.json")) {
            _ = try await store.put("v1/a.json", Data("3".utf8), when: .matching(first))
        }
        #expect(try await store.get("v1/a.json")?.etag == second)
    }

    /// Rule 8: an `If-Match` on a key that is gone is a conflict too (404 from a bucket).
    @Test(arguments: kinds)
    func matchingAGoneKeyConflicts(_ kind: Kind) async throws {
        let store = try Self.make(kind)
        let tag = try await store.put("v1/a.json", Data("1".utf8), when: .absent)
        try await store.delete("v1/a.json")
        await #expect(throws: StoreError.conflict(key: "v1/a.json")) {
            _ = try await store.put("v1/a.json", Data("2".utf8), when: .matching(tag))
        }
    }

    @Test(arguments: kinds)
    func listSeesNewKeys(_ kind: Kind) async throws {
        let store = try Self.make(kind)
        #expect(try await store.list(prefix: "v1/clients/").isEmpty)
        let tag = try await store.put("v1/clients/one.json", Data("1".utf8), when: .absent)
        _ = try await store.put("v1/hosts/mac.json", Data("2".utf8), when: .absent)
        let listed = try await store.list(prefix: "v1/clients/")
        #expect(listed == [StoredKey(key: "v1/clients/one.json", etag: tag)])
        #expect(try await store.list(prefix: "v1/").count == 2)
    }

    /// A spent code is written once however many copies race to use it.
    @Test(arguments: kinds)
    func oneOfTwentyRacingCreatesWins(_ kind: Kind) async throws {
        let store = try Self.make(kind)
        let winners = await withTaskGroup(of: Bool.self) { group in
            for n in 0..<20 {
                group.addTask {
                    (try? await store.put("v1/codes/x.spent", Data("\(n)".utf8), when: .absent)) != nil
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(winners == 1)
    }

    /// Rules 10 and 11: every change bumps `rev`, so a write made against A is refused
    /// after A→B→A; and a forget is a tombstone that reads as absent.
    @Test(arguments: kinds)
    func revAndTombstones(_ kind: Kind) async throws {
        let store = try Self.make(kind)
        let records = ControlRecords(store: store)
        try await records.load()
        let id = UUID()
        let client = ClientRecord(id: id, name: "phone", kind: .iPhone, publicKey: Data(repeating: 1, count: 65),
                                  grant: .device, paired: Date())
        // Another operator, so the last-operator rule lets this one's grant move.
        try await records.save(ClientRecord(id: UUID(), name: "mac", kind: .mac, publicKey: Data(repeating: 2, count: 65),
                                            grant: .operator, paired: Date()))
        try await records.save(client)
        let seenAtA = try #require(try await store.get(ControlRecords.clientKey(id))).etag
        try await records.setGrant(.operator, of: id)
        try await records.setGrant(.device, of: id)
        let backAtA = try #require(try await store.get(ControlRecords.clientKey(id))).etag
        #expect(backAtA != seenAtA)
        await #expect(throws: StoreError.conflict(key: ControlRecords.clientKey(id))) {
            _ = try await store.put(ControlRecords.clientKey(id), Data("{}".utf8),
                                    when: .matching(seenAtA))
        }

        try await records.forget(id)
        #expect(try await store.get(ControlRecords.clientKey(id)) != nil)
        let fresh = ControlRecords(store: store)
        try await fresh.load()
        #expect(await fresh.client(id) == nil)
    }

    @Test(arguments: kinds)
    func theProbePasses(_ kind: Kind) async throws {
        try await Self.make(kind).probe(copy: "test")
    }

    /// A bucket that ignores `If-None-Match` and `If-Match`: the probe refuses it.
    @Test func theProbeRefusesAStoreThatIgnoresConditions() async throws {
        actor Careless: ControlStore {
            var objects: [String: StoredObject] = [:]
            func get(_ key: String) async throws -> StoredObject? { objects[key] }
            func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
                let tag = UUID().uuidString
                objects[key] = StoredObject(data: data, etag: tag)
                return tag
            }
            func delete(_ key: String) async throws { objects[key] = nil }
            func list(prefix: String) async throws -> [StoredKey] { [] }
        }
        await #expect(throws: StoreError.self) { try await Careless().probe(copy: "test") }
    }

    /// The signer, against AWS's published example (SigV4 "GET Object" with a range).
    @Test func theSignatureMatchesAWSsExample() throws {
        let store = S3Store(.init(endpoint: URL(string: "https://s3.amazonaws.com")!, bucket: "examplebucket"),
                            credentials: .init(accessKey: "AKIAIOSFODNN7EXAMPLE",
                                               secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))
        let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
        let signed = store.request("GET", key: "test.txt", body: Data(), headers: [("range", "bytes=0-9")],
                                   query: [], now: date)
        let authorization = signed.headers.first { $0.0 == "authorization" }?.1 ?? ""
        #expect(authorization.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
        #expect(signed.url == "https://examplebucket.s3.amazonaws.com/test.txt")
    }
}
