import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// Switch Store… (058, T058b; contracts/store.md "Copying a store").
@Suite("Copying a store")
struct StoreCopyTests {
    func filled() async throws -> (store: FolderStore, records: [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)")
        let store = FolderStore(root: root)
        let records = ControlRecords(store: store)
        try await records.load()
        _ = try await records.settings { ControlSettings(name: "mini", machineID: "m") }
        for n in 0..<3 {
            try await records.save(ClientRecord(id: UUID(), name: "client \(n)", kind: .iPhone,
                                                publicKey: Data(repeating: UInt8(n), count: 65), grant: .device, paired: Date()))
        }
        try await records.save(HostRecord(id: .mac, name: "This Mac"))
        _ = try await store.put("v1/leases/mac.json", Data("{}".utf8), when: .absent)
        _ = try await store.put("v1/copies/one.json", Data("{}".utf8), when: .always)
        let kept = try await store.list(prefix: "v1/").map(\.key).filter { !StoreCopy.isSkipped($0) }
        return (store, kept)
    }

    @Test func folderToMemoryAndBack() async throws {
        let (folder, kept) = try await filled()
        let memory = MemoryStore()
        let there = try await StoreCopy.copy(from: folder, to: memory)
        #expect(there == .init(copied: kept.count, skipped: 2))
        #expect(try await memory.get("v1/leases/mac.json") == nil)

        let back = FolderStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("back-\(UUID().uuidString)"))
        _ = try await StoreCopy.copy(from: memory, to: back)
        for key in kept {
            #expect(try await back.get(key)?.data == folder.get(key)?.data, "\(key)")
        }
        // Every record intact: read back as records, not just bytes.
        let read = ControlRecords(store: back)
        try await read.load()
        #expect(await read.clients.count == 3)
        #expect(await read.host(.mac)?.name == "This Mac")
        #expect(await read.settings?.name == "mini")
    }

    @Test func aDestinationInUseIsRefused() async throws {
        let (folder, _) = try await filled()
        let (other, _) = try await filled()
        await #expect(throws: StoreCopy.Failure.destinationInUse) {
            _ = try await StoreCopy.copy(from: folder, to: other)
        }
    }

    @Test func theAddressNamesTheStore() throws {
        #expect(try StoreAddress.open("file:///tmp/x", environment: [:]) is FolderStore)
        let bucket = try StoreAddress.open("s3://agents/control", environment: [
            "AGENTS_STORE_ENDPOINT": "http://127.0.0.1:9000", "AGENTS_STORE_PATH_STYLE": "1",
            "AWS_ACCESS_KEY_ID": "a", "AWS_SECRET_ACCESS_KEY": "b"])
        let location = try #require(bucket as? S3Store).location
        #expect(location == .init(endpoint: URL(string: "http://127.0.0.1:9000")!, bucket: "agents", prefix: "control",
                                  pathStyle: true))
        #expect(throws: StoreAddress.Failure.noCredentials) {
            _ = try StoreAddress.open("s3://agents", environment: ["HOME": "/nonexistent"])
        }
    }
}
