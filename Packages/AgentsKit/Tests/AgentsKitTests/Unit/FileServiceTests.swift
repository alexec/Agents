import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Reading on an agent's behalf (046): a file that is not there yet is "Resource not
/// found", the protocol's own words, which Gemini's write_file needs to see before it will
/// create one.
@Suite("Reading a file for an agent")
struct FileServiceTests {
    @Test func aFileNotThereYetIsResourceNotFound() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = FileService(scope: FolderScope(folders: [folder]))

        let missing = folder.appendingPathComponent("hello.txt").path
        guard case .failed(let message) = service.read(path: missing, line: nil, limit: nil) else {
            Issue.record("read something that is not there"); return
        }
        #expect(message.hasPrefix("Resource not found"))

        // A folder exists but is not text: that is not "not found".
        guard case .failed(let other) = service.read(path: folder.path, line: nil, limit: nil) else {
            Issue.record("read a folder"); return
        }
        #expect(other.hasPrefix("There is nothing readable"))
    }
}
