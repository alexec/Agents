import Foundation
import Testing
@testable import AgentsKitCore

/// Export… and Import… (#1001): the parts a client reads and sends, and its words.
@Suite("Export and import")
struct AgentsExportTransferTests {
    /// A host with one export of three parts, that keeps what an import sends.
    final class Host: DaemonLink, @unchecked Sendable {
        let parts = [Data("one-".utf8), Data("two-".utf8), Data("three".utf8)]
        private let lock = NSLock()
        private var _received: [(offset: Int, data: Data)] = []
        private var _imported: String?
        private var _importedInto: String?
        var received: [(offset: Int, data: Data)] { lock.withLock { _received } }
        var imported: String? { lock.withLock { _imported } }
        var importedInto: String? { lock.withLock { _importedInto } }

        func transport() async throws -> any LineTransport {
            let (near, far) = PairedTransport.pair()
            _ = Task {
                for try await line in far.lines() {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let id = object["id"] as? Int, let method = object["method"] as? String else { continue }
                    let params = object["params"] as? [String: Any] ?? [:]
                    try? far.write(line: #"{"jsonrpc":"2.0","id":\#(id),"result":\#(answer(method, params))}"#)
                }
            }
            return near
        }

        private func answer(_ method: String, _ params: [String: Any]) -> String {
            switch method {
            case DaemonAPI.Method.agentsExport:
                let size = parts.reduce(0) { $0 + $1.count }
                return #"{"file":{"id":"\#(UUID().uuidString)","size":\#(size)},"agents":2,"name":"Fix the build 2026-10-22.tar.gz"}"#
            case DaemonAPI.Method.agentsExportRead:
                var offset = params["offset"] as? Int ?? 0
                for (index, part) in parts.enumerated() {
                    if offset == 0 {
                        return #"{"data":"\#(part.base64EncodedString())","end":\#(index == parts.count - 1)}"#
                    }
                    offset -= part.count
                }
                return #"{"data":"","end":true}"#
            case DaemonAPI.Method.agentsImportUpload:
                let data = Data(base64Encoded: params["data"] as? String ?? "") ?? Data()
                lock.withLock { _received.append((params["offset"] as? Int ?? -1, data)) }
                return "{}"
            case DaemonAPI.Method.agentsImport:
                lock.withLock { (_imported, _importedInto) = (params["upload"] as? String, params["folder"] as? String) }
                return #"{"restored":2,"skipped":1}"#
            default:
                return "{}"
            }
        }
    }

    @Test func anExportIsReadInPartsIntoAFile() async throws {
        let host = Host()
        let client = DaemonClient(link: host)
        try await client.connect(startIfNeeded: false)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let made = try await AgentsExportTransfer.make(DaemonAPI.AgentsExportRequest(agentID: UUID()), on: client)
        #expect(made.agents == 2)
        #expect(made.name == "Fix the build 2026-10-22.tar.gz")
        let file = folder.appending(path: made.name)
        let seen = Seen()
        try await AgentsExportTransfer.read(made, from: client, into: file) { seen.add($0, $1) }
        #expect(try Data(contentsOf: file) == Data("one-two-three".utf8))
        // How far it is, after each part, of the whole the host said (#2437).
        #expect(seen.all.map(\.0) == [4, 8, 13])
        #expect(seen.all.allSatisfy { $0.1 == 13 })
    }

    /// What a progress callback heard, in order.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [(Int, Int)] = []
        var all: [(Int, Int)] { lock.withLock { _all } }
        func add(_ done: Int, _ whole: Int) { lock.withLock { _all.append((done, whole)) } }
    }

    /// Cancel stops an import between parts, and nothing is imported (#2437).
    @Test func aCancelledImportImportsNothing() async throws {
        let host = Host()
        let client = DaemonClient(link: host)
        try await client.connect(startIfNeeded: false)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".tar.gz")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(count: AgentsExportTransfer.partSize * 3).write(to: file)

        let task = Task {
            try await AgentsExportTransfer.importFile(file, into: client) { done, _ in
                if done >= AgentsExportTransfer.partSize { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(host.received.count == 1)
        #expect(host.imported == nil)
    }

    @Test func theBusyLinesSayWhatIsGoingOn() {
        #expect(AgentsExportTransfer.exporting(nil) == "Making the export…")
        #expect(AgentsExportTransfer.exporting(1) == "Exporting 1 agent…")
        #expect(AgentsExportTransfer.exporting(12) == "Exporting 12 agents…")
        #expect(AgentsExportTransfer.importing(sent: false) == "Sending the export…")
        #expect(AgentsExportTransfer.importing(sent: true) == "Importing the agents…")
        #expect(AgentsExportTransfer.exported(1) == "Exported 1 agent.")
        #expect(AgentsExportTransfer.exported(12) == "Exported 12 agents.")
    }

    @Test func anImportIsSentInPartsThenImported() async throws {
        let host = Host()
        let client = DaemonClient(link: host)
        try await client.connect(startIfNeeded: false)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".tar.gz")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data((0..<(AgentsExportTransfer.partSize * 2 + 10)).map { UInt8($0 % 251) })
        try bytes.write(to: file)

        let folder = URL(fileURLWithPath: "/tmp/B", isDirectory: true)
        let result = try await AgentsExportTransfer.importFile(file, into: client, folder: folder)
        #expect(result == DaemonAPI.BackupRestoreResult(restored: 2, skipped: 1))
        #expect(host.received.map(\.offset) == [0, AgentsExportTransfer.partSize, AgentsExportTransfer.partSize * 2])
        #expect(host.received.reduce(Data()) { $0 + $1.data } == bytes)
        #expect(host.imported != nil)
        // Into the folder whose menu was used (#2389).
        #expect(host.importedInto == folder.absoluteString)
    }

    @Test func theWordsSayWhatAnImportDid() {
        typealias R = DaemonAPI.BackupRestoreResult
        #expect(AgentsExportTransfer.imported(R(restored: 1, skipped: 0)) == "Imported 1 agent, archived.")
        #expect(AgentsExportTransfer.imported(R(restored: 3, skipped: 0)) == "Imported 3 agents, archived.")
        #expect(AgentsExportTransfer.imported(R(restored: 2, skipped: 1))
            == "Imported 2 agents, archived. 1 was skipped: already here, or deleted here.")
        #expect(AgentsExportTransfer.imported(R(restored: 0, skipped: 2))
            == "Imported no agents. 2 were skipped: already here, or deleted here.")
        #expect(AgentsExportTransfer.imported(R(restored: 0, skipped: 0)) == "There were no agents to import.")
        #expect(AgentsExportTransfer.imported(R(restored: 2, skipped: 0), into: "Web") == "Imported 2 agents into Web, archived.")
    }
}
