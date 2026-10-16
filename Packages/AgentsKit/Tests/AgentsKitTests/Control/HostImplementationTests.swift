import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A host says which language it is written in (#1134), and Hosts shows it.
@Suite("A host's implementation")
struct HostImplementationTests {
    func methods() async throws -> (ControlMethods, ControlRecords) {
        let records = ControlRecords(store: MemoryStore())
        let settings = try await records.settings(orMake: { ControlSettings(name: "test", machineID: "m") })
        return (ControlMethods(records: records, settings: settings, version: "1"), records)
    }

    @Test func itIsKeptFromTheHelloAndListed() async throws {
        let (methods, records) = try await methods()
        let id = HostID(rawValue: "go000000")
        try await methods.enroll(HostRecord(id: id, name: "devbox"))
        _ = try await methods.hostSaid(id, method: DaemonAPI.Method.hostHello, params: try JSONValue.encoding(
            DaemonAPI.HostHello(version: "1.0", platform: "Linux arm64", machineID: "srv", implementation: "go")))
        let record = try #require(await records.host(id))
        #expect(record.implementation == "go")
        #expect(await methods.hostRow(record).implementation == "go")

        // Changed back to the Swift host on the same root: the next hello says so.
        _ = try await methods.hostSaid(id, method: DaemonAPI.Method.hostHello, params: try JSONValue.encoding(
            DaemonAPI.HostHello(version: "1.0", platform: "Linux arm64", machineID: "srv", implementation: "swift")))
        #expect(await records.host(id)?.implementation == "swift")
    }

    /// A host from before the field says nothing, and is read as it always was.
    @Test func anOlderHelloSaysNothing() throws {
        let hello = try JSONDecoder().decode(DaemonAPI.HostHello.self,
                                             from: Data(#"{"version":"1","platform":"Linux arm64","machineID":"m"}"#.utf8))
        #expect(hello.implementation == nil)
        let record = try JSONDecoder().decode(HostRecord.self, from: JSONEncoder().encode(HostRecord(id: HostID(rawValue: "a"), name: "a")))
        #expect(record.implementation == nil)
    }
}
